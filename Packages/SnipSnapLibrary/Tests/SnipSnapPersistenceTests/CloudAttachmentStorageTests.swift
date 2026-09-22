import CryptoKit
import Darwin
import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapPersistence

final class CloudAttachmentStorageTests: XCTestCase {
  func testSeparateManifestsSharingACacheBaseDoNotDeleteEachOthersCaches() async throws {
    let parent = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: parent) }
    let cacheRoot = parent.appendingPathComponent("Cache", isDirectory: true)
    let first = try SwiftDataSyncModePersistence(
      rootURL: parent.appendingPathComponent("FirstManifest", isDirectory: true),
      attachmentCacheRootURL: cacheRoot
    )
    let firstStoreID = try await first.snapshot().activeStore.id
    let firstCache = try XCTUnwrap(
      SwiftDataSyncModePersistence.cacheRootURL(base: cacheRoot, storeID: firstStoreID)
    )
    try FileManager.default.createDirectory(at: firstCache, withIntermediateDirectories: true)
    let firstMarker = firstCache.appendingPathComponent("first")
    try Data("first cached bytes".utf8).write(to: firstMarker)

    let second = try SwiftDataSyncModePersistence(
      rootURL: parent.appendingPathComponent("SecondManifest", isDirectory: true),
      attachmentCacheRootURL: cacheRoot
    )
    let secondStoreID = try await second.snapshot().activeStore.id
    let secondCache = try XCTUnwrap(
      SwiftDataSyncModePersistence.cacheRootURL(base: cacheRoot, storeID: secondStoreID)
    )
    try FileManager.default.createDirectory(at: secondCache, withIntermediateDirectories: true)
    let secondMarker = secondCache.appendingPathComponent("second")
    try Data("second cached bytes".utf8).write(to: secondMarker)

    _ = try SwiftDataSyncModePersistence(
      rootURL: parent.appendingPathComponent("FirstManifest", isDirectory: true),
      attachmentCacheRootURL: cacheRoot
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: firstMarker.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondMarker.path))
  }

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
    XCTAssertEqual(
      try uploadRoot.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
      true
    )
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
    let cached = try await library.installCloudAttachmentDownload(
      namespaceKey: namespace,
      attachmentID: attachmentID,
      expectedPayloadIdentity: payload,
      expectedField: "asset",
      download: CloudAttachmentCacheDownload(
        payloadIdentity: payload,
        field: "asset",
        fileURL: staged,
        byteCount: Int64(bytes.count),
        sha256: Data(SHA256.hash(data: bytes))
      ),
      maximumBytes: 1_024,
      now: .distantPast
    )
    XCTAssertTrue(cached.path.contains("CloudDownloads"))
    XCTAssertEqual(
      try cached.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
      true
    )

    let namespaceRoot = cached.deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let actualNamespaceRoot = root.appendingPathComponent("AliasedCacheNamespace")
    try FileManager.default.moveItem(at: namespaceRoot, to: actualNamespaceRoot)
    try FileManager.default.createSymbolicLink(
      at: namespaceRoot,
      withDestinationURL: actualNamespaceRoot
    )

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
    XCTAssertFalse(FileManager.default.fileExists(atPath: actualNamespaceRoot.path))
  }

  func testCacheInstallDoesNotRequireDirectoryReadAccessToAStagedFile() async throws {
    if geteuid() == 0 { throw XCTSkip("Root bypasses directory permissions.") }
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
    let namespace = CloudSyncNamespaceKey(rawValue: "restricted-staging-directory")
    let attachmentID = UUID()
    let payload = CloudTextStorageIdentity(
      zoneName: "payload", ownerName: "owner", recordName: UUID().uuidString.lowercased()
    )
    let bytes = Data("downloaded through a file grant".utf8)
    let metadata = CloudAttachmentMetadataValue(
      attachmentID: attachmentID,
      snipID: snipID,
      position: 0,
      fileName: "download.txt",
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
    let restrictedDirectory = stagingRoot.appendingPathComponent("download", isDirectory: true)
    let staged = restrictedDirectory.appendingPathComponent("payload")
    try FileManager.default.createDirectory(
      at: restrictedDirectory,
      withIntermediateDirectories: true
    )
    try bytes.write(to: staged)
    defer {
      chmod(restrictedDirectory.path, 0o700)
      try? FileManager.default.removeItem(at: root)
    }
    XCTAssertEqual(chmod(restrictedDirectory.path, 0o300), 0)
    XCTAssertEqual(try Data(contentsOf: staged), bytes)
    let directory = open(restrictedDirectory.path, O_RDONLY | O_DIRECTORY)
    if directory >= 0 { close(directory) }
    XCTAssertEqual(directory, -1)

    let cached = try await library.installCloudAttachmentDownload(
      namespaceKey: namespace,
      attachmentID: attachmentID,
      expectedPayloadIdentity: payload,
      expectedField: "asset",
      download: CloudAttachmentCacheDownload(
        payloadIdentity: payload,
        field: "asset",
        fileURL: staged,
        byteCount: Int64(bytes.count),
        sha256: metadata.sha256
      ),
      maximumBytes: 1_024,
      now: .distantPast
    )

    XCTAssertEqual(try Data(contentsOf: cached), bytes)
  }

  func testLegacyDownloadMigratesToPurgeableCacheAndEvictionBecomesCacheMiss() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    var legacyLibrary: SwiftDataSnipLibrary? = try SwiftDataSnipLibrary(storeURL: storeURL)
    let added = try await legacyLibrary!.perform(
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
    let namespace = CloudSyncNamespaceKey(rawValue: "cache-location-migration")
    let attachmentID = UUID()
    let payload = CloudTextStorageIdentity(
      zoneName: "payload", ownerName: "owner", recordName: UUID().uuidString.lowercased()
    )
    let bytes = Data("re-downloadable legacy cache".utf8)
    let digest = Data(SHA256.hash(data: bytes))
    let metadata = CloudAttachmentMetadataValue(
      attachmentID: attachmentID,
      snipID: snipID,
      position: 0,
      fileName: "cached.txt",
      contentType: "text/plain",
      byteCount: Int64(bytes.count),
      sha256: digest,
      payloadIdentity: payload
    )
    try await legacyLibrary!.commitCloudAttachmentTransitions(
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
    let stagingRoot = try await legacyLibrary!.cloudAttachmentStagingRoot(namespaceKey: namespace)
    let staged = stagingRoot.appendingPathComponent("download/payload")
    try FileManager.default.createDirectory(
      at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try bytes.write(to: staged)
    let legacyURL = try await legacyLibrary!.installCloudAttachmentDownload(
      namespaceKey: namespace,
      attachmentID: attachmentID,
      expectedPayloadIdentity: payload,
      expectedField: "asset",
      download: CloudAttachmentCacheDownload(
        payloadIdentity: payload,
        field: "asset",
        fileURL: staged,
        byteCount: Int64(bytes.count),
        sha256: digest
      ),
      maximumBytes: 1_024,
      now: .distantPast
    )
    XCTAssertTrue(legacyURL.path.contains("/Attachments/CloudDownloads/"))
    legacyLibrary = nil

    let cacheContainer = root
      .appendingPathComponent("Group", isDirectory: true)
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Caches", isDirectory: true)
      .appendingPathComponent("SnipSnap", isDirectory: true)
      .appendingPathComponent("CloudAttachments", isDirectory: true)
    try FileManager.default.createDirectory(
      at: cacheContainer.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("temporarily blocks cache creation".utf8).write(to: cacheContainer)
    let library = try SwiftDataSnipLibrary(
      storeURL: storeURL,
      attachmentCacheRootURL: cacheContainer
    )
    let compatible = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(compatible.attachmentURLs[attachmentID], legacyURL)

    try await library.sweepCloudAttachmentCache(namespaceKey: namespace, maximumBytes: 1_024)
    let afterFailedMigration = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(afterFailedMigration.attachmentURLs[attachmentID], legacyURL)
    XCTAssertEqual(try Data(contentsOf: legacyURL), bytes)

    try FileManager.default.removeItem(at: cacheContainer)
    let legacyRelativePath = legacyURL.pathComponents.suffix(3).joined(separator: "/")
    let interruptedDestination = cacheContainer
      .appendingPathComponent("CloudDownloads", isDirectory: true)
      .appendingPathComponent(CloudAttachmentCacheFiles.namespaceDigest(namespace.rawValue))
      .appendingPathComponent(legacyRelativePath)
    try FileManager.default.createDirectory(
      at: interruptedDestination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("partial interrupted copy".utf8).write(to: interruptedDestination)
    try await library.sweepCloudAttachmentCache(namespaceKey: namespace, maximumBytes: 1_024)

    let migratedStorage = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace)
    let migratedURL = try XCTUnwrap(migratedStorage.cacheEntries.first?.fileURL)
    XCTAssertTrue(migratedURL.path.hasPrefix(cacheContainer.path + "/"))
    XCTAssertEqual(try Data(contentsOf: migratedURL), bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    XCTAssertEqual(
      try migratedURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
      true
    )
    let migratedSnapshot = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(migratedSnapshot.attachmentURLs[attachmentID], migratedURL)

    let namespaceRoot = migratedURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let actualNamespaceRoot = root.appendingPathComponent(
      "ActualPurgeableNamespace",
      isDirectory: true
    )
    try FileManager.default.moveItem(at: namespaceRoot, to: actualNamespaceRoot)
    try FileManager.default.createSymbolicLink(
      at: namespaceRoot,
      withDestinationURL: actualNamespaceRoot
    )
    let aliasedSnapshot = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(aliasedSnapshot.attachmentURLs[attachmentID], migratedURL)
    XCTAssertEqual(try Data(contentsOf: migratedURL), bytes)
    try await library.sweepCloudAttachmentCache(namespaceKey: namespace, maximumBytes: 1_024)
    let touchedThroughAlias = try await library.touchCloudAttachmentCache(
      namespaceKey: namespace,
      attachmentID: attachmentID,
      now: Date(timeIntervalSince1970: 1)
    )
    XCTAssertEqual(touchedThroughAlias, migratedURL)

    try FileManager.default.removeItem(at: migratedURL)
    let evicted = try await library.touchCloudAttachmentCache(
      namespaceKey: namespace,
      attachmentID: attachmentID,
      now: Date(timeIntervalSince1970: 1)
    )
    XCTAssertNil(evicted)
    let afterEviction = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace)
    XCTAssertTrue(afterEviction.cacheEntries.isEmpty)
    XCTAssertEqual(afterEviction.publications.map(\.metadata.attachmentID), [attachmentID])
    let missingBytes = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertNil(missingBytes.attachmentURLs[attachmentID])
  }

  func testStagedFileValidationTrustsOnlyTheAppOwnedNamespaceRootAlias() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = CloudAttachmentCacheFiles(
      attachmentRootURL: root.appendingPathComponent("Attachments", isDirectory: true),
      lockURL: root.appendingPathComponent("snips.store.lock", isDirectory: false)
    )
    let namespace = "app-owned-directory-alias"
    let stagingRoot = try files.stagingRoot(namespaceKey: namespace)
    let namespaceRoot = stagingRoot.deletingLastPathComponent()
    let actualNamespaceRoot = root.appendingPathComponent("ActualNamespace", isDirectory: true)
    try FileManager.default.moveItem(at: namespaceRoot, to: actualNamespaceRoot)
    try FileManager.default.createSymbolicLink(
      at: namespaceRoot,
      withDestinationURL: actualNamespaceRoot
    )
    let bytes = Data("downloaded through an app-owned alias".utf8)
    let staged = stagingRoot.appendingPathComponent("cloud-asset")
    try bytes.write(to: staged)

    XCTAssertNoThrow(
      try files.validateStagedFile(
        staged,
        namespaceKey: namespace,
        expectedByteCount: Int64(bytes.count),
        expectedSHA256: Data(SHA256.hash(data: bytes))
      )
    )
  }

  func testStagedFileValidationRejectsAStagingDirectorySymlink() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = CloudAttachmentCacheFiles(
      attachmentRootURL: root.appendingPathComponent("Attachments", isDirectory: true),
      lockURL: root.appendingPathComponent("snips.store.lock", isDirectory: false)
    )
    let namespace = "staging-descendant-alias"
    let stagingRoot = try files.stagingRoot(namespaceKey: namespace)
    let outside = root.appendingPathComponent("OutsideStaging", isDirectory: true)
    try FileManager.default.moveItem(at: stagingRoot, to: outside)
    try FileManager.default.createSymbolicLink(at: stagingRoot, withDestinationURL: outside)
    let staged = stagingRoot.appendingPathComponent("cloud-asset")
    let bytes = Data("must not escape through staging".utf8)
    try bytes.write(to: staged)

    XCTAssertThrowsError(
      try files.validateStagedFile(
        staged,
        namespaceKey: namespace,
        expectedByteCount: Int64(bytes.count),
        expectedSHA256: Data(SHA256.hash(data: bytes))
      )
    ) { error in
      XCTAssertEqual(error as? CloudAttachmentStorageError, .symbolicLinkDescendant)
    }
    files.discardStagedFileIfSafe(staged, namespaceKey: namespace)
    XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
  }

  func testCanonicalStagedReceiptRejectsAnIntermediateSymlinkBelowAliasedRoot() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = CloudAttachmentCacheFiles(
      attachmentRootURL: root.appendingPathComponent("Attachments", isDirectory: true),
      lockURL: root.appendingPathComponent("snips.store.lock", isDirectory: false)
    )
    let namespace = "canonical-receipt-descendant-alias"
    let stagingRoot = try files.stagingRoot(namespaceKey: namespace)
    let namespaceRoot = stagingRoot.deletingLastPathComponent()
    let actualNamespaceRoot = root.appendingPathComponent("ActualNamespace", isDirectory: true)
    try FileManager.default.moveItem(at: namespaceRoot, to: actualNamespaceRoot)
    try FileManager.default.createSymbolicLink(
      at: namespaceRoot,
      withDestinationURL: actualNamespaceRoot
    )
    let actualStagingRoot = actualNamespaceRoot.appendingPathComponent(
      "Staging", isDirectory: true
    )
    let target = actualStagingRoot.appendingPathComponent("Target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let link = actualStagingRoot.appendingPathComponent("Link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let staged = link.appendingPathComponent("payload")
    let bytes = Data("must retain descendant symlink evidence".utf8)
    try bytes.write(to: staged)

    XCTAssertThrowsError(
      try files.validateStagedFile(
        staged,
        namespaceKey: namespace,
        expectedByteCount: Int64(bytes.count),
        expectedSHA256: Data(SHA256.hash(data: bytes))
      )
    ) { error in
      XCTAssertEqual(error as? CloudAttachmentStorageError, .symbolicLinkDescendant)
    }
    files.discardStagedFileIfSafe(staged, namespaceKey: namespace)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: target.appendingPathComponent("payload").path)
    )
  }

  func testStagedCleanupRefusesADirectoryReceipt() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = CloudAttachmentCacheFiles(
      attachmentRootURL: root.appendingPathComponent("Attachments", isDirectory: true),
      lockURL: root.appendingPathComponent("snips.store.lock", isDirectory: false)
    )
    let namespace = "directory-receipt"
    let stagedDirectory = try files.stagingRoot(namespaceKey: namespace)
      .appendingPathComponent("download", isDirectory: true)
    try FileManager.default.createDirectory(
      at: stagedDirectory,
      withIntermediateDirectories: true
    )
    let otherDownload = stagedDirectory.appendingPathComponent("other-download")
    try Data("must survive".utf8).write(to: otherDownload)

    files.discardStagedFileIfSafe(stagedDirectory, namespaceKey: namespace)

    XCTAssertEqual(try Data(contentsOf: otherDownload), Data("must survive".utf8))
  }

  func testUnavailableStoreStillDiscardsItsStagedDownload() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = SwiftDataSnipLibrary.unavailable(storeURL: root.appendingPathComponent("store"))
    let namespace = CloudSyncNamespaceKey(rawValue: "unavailable-store")
    let stagingRoot = try await library.cloudAttachmentStagingRoot(namespaceKey: namespace)
    let staged = stagingRoot.appendingPathComponent("download/payload")
    try FileManager.default.createDirectory(
      at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let bytes = Data("discard me".utf8)
    try bytes.write(to: staged)
    let payload = CloudTextStorageIdentity(
      zoneName: "payload", ownerName: "owner", recordName: "record"
    )

    do {
      _ = try await library.installCloudAttachmentDownload(
        namespaceKey: namespace,
        attachmentID: UUID(),
        expectedPayloadIdentity: payload,
        expectedField: "asset",
        download: CloudAttachmentCacheDownload(
          payloadIdentity: payload,
          field: "asset",
          fileURL: staged,
          byteCount: Int64(bytes.count),
          sha256: Data(SHA256.hash(data: bytes))
        ),
        maximumBytes: 1_024,
        now: .distantPast
      )
      XCTFail("Expected an unavailable store")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .storeUnavailable)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
  }

  func testCacheInstallTrustsAppOwnedDirectoryAliases() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = CloudAttachmentCacheFiles(
      attachmentRootURL: root.appendingPathComponent("Attachments", isDirectory: true),
      lockURL: root.appendingPathComponent("snips.store.lock", isDirectory: false)
    )
    let namespace = "app-owned-cache-alias"
    let cacheRoot = try files.cacheRoot(namespaceKey: namespace)
    let actualCacheRoot = root.appendingPathComponent("ActualCache", isDirectory: true)
    try FileManager.default.moveItem(at: cacheRoot, to: actualCacheRoot)
    try FileManager.default.createSymbolicLink(
      at: cacheRoot,
      withDestinationURL: actualCacheRoot
    )
    _ = try files.stagingRoot(namespaceKey: namespace)
    let bytes = Data("downloaded through an app-owned cache alias".utf8)
    let staged = actualCacheRoot
      .appendingPathComponent("Staging", isDirectory: true)
      .appendingPathComponent("cloud-asset")
    try bytes.write(to: staged)
    let relativePath = "Files/\(UUID().uuidString.lowercased())/payload"

    try files.validateStagedFile(
      staged,
      namespaceKey: namespace,
      expectedByteCount: Int64(bytes.count),
      expectedSHA256: Data(SHA256.hash(data: bytes))
    )
    let cached = try files.installStagedFile(
      staged,
      namespaceKey: namespace,
      relativePath: relativePath
    )

    XCTAssertEqual(try Data(contentsOf: cached), bytes)
  }

  func testCacheInstallTrustsFileReferenceCacheRoot() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheContainer = root.appendingPathComponent("Cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheContainer, withIntermediateDirectories: true)
    let fileReferenceCacheContainer = try XCTUnwrap(
      (cacheContainer as NSURL).fileReferenceURL()
    )
    let files = CloudAttachmentCacheFiles(
      attachmentRootURL: root.appendingPathComponent("Attachments", isDirectory: true),
      lockURL: root.appendingPathComponent("snips.store.lock", isDirectory: false),
      cacheContainerURL: fileReferenceCacheContainer
    )
    let namespace = "file-reference-cache-root"
    let stagingRoot = try files.stagingRoot(namespaceKey: namespace)
    let bytes = Data("downloaded through a file-reference cache root".utf8)
    let staged = stagingRoot.appendingPathComponent("cloud-asset")
    try bytes.write(to: staged)
    let relativePath = "Files/\(UUID().uuidString.lowercased())/payload"

    try files.validateStagedFile(
      staged,
      namespaceKey: namespace,
      expectedByteCount: Int64(bytes.count),
      expectedSHA256: Data(SHA256.hash(data: bytes))
    )
    let cached = try files.installStagedFile(
      staged,
      namespaceKey: namespace,
      relativePath: relativePath
    )

    XCTAssertEqual(try Data(contentsOf: cached), bytes)
    let dangling = try files.cacheRoot(namespaceKey: namespace)
      .appendingPathComponent("Files", isDirectory: true)
      .appendingPathComponent("dangling-payload")
    try FileManager.default.createSymbolicLink(
      at: dangling,
      withDestinationURL: root.appendingPathComponent("missing-payload")
    )
    XCTAssertThrowsError(
      try files.cacheFileURL(relativePath: "Files/dangling-payload", namespaceKey: namespace)
    ) { error in
      XCTAssertEqual(error as? CloudAttachmentStorageError, .symbolicLinkDescendant)
    }
  }

  func testCachePathsStillRejectInvalidRelativeComponents() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = CloudAttachmentCacheFiles(
      attachmentRootURL: root.appendingPathComponent("Attachments", isDirectory: true),
      lockURL: root.appendingPathComponent("snips.store.lock", isDirectory: false)
    )

    let invalidPaths = [
      "", "/outside", "../outside", "Files//payload", "Files/./payload", "\u{0}",
      "..\u{0}/outside", "Files/..\u{0}/..\u{0}/outside",
    ]
    for relativePath in invalidPaths {
      XCTAssertThrowsError(
        try files.cacheFileURL(
          relativePath: relativePath,
          namespaceKey: "invalid-cache-relative-path"
        )
      ) { error in
        XCTAssertEqual(error as? CloudAttachmentStorageError, .invalidRelativePath)
      }
    }
  }

  func testCachePathsRejectDanglingSymlinkDescendants() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = CloudAttachmentCacheFiles(
      attachmentRootURL: root.appendingPathComponent("Attachments", isDirectory: true),
      lockURL: root.appendingPathComponent("snips.store.lock", isDirectory: false)
    )
    let namespace = "dangling-cache-symlink"
    let cacheRoot = try files.cacheRoot(namespaceKey: namespace)
    let filesRoot = cacheRoot.appendingPathComponent("Files", isDirectory: true)
    try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)

    let danglingDirectory = filesRoot.appendingPathComponent("dangling-directory")
    try FileManager.default.createSymbolicLink(
      at: danglingDirectory,
      withDestinationURL: root.appendingPathComponent("missing-directory")
    )
    XCTAssertThrowsError(
      try files.cacheFileURL(
        relativePath: "Files/dangling-directory/payload",
        namespaceKey: namespace
      )
    ) { error in
      XCTAssertEqual(error as? CloudAttachmentStorageError, .symbolicLinkDescendant)
    }

    let danglingLeaf = filesRoot.appendingPathComponent("dangling-leaf")
    try FileManager.default.createSymbolicLink(
      at: danglingLeaf,
      withDestinationURL: root.appendingPathComponent("missing-leaf")
    )
    XCTAssertThrowsError(
      try files.cacheFileURL(relativePath: "Files/dangling-leaf", namespaceKey: namespace)
    ) { error in
      XCTAssertEqual(error as? CloudAttachmentStorageError, .symbolicLinkDescendant)
    }
  }

  func testNonCachePathsStillRejectASymlinkRoot() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let actualRoot = root.appendingPathComponent("ActualUploadRoot", isDirectory: true)
    let symlinkRoot = root.appendingPathComponent("UploadRoot", isDirectory: true)
    try FileManager.default.createDirectory(at: actualRoot, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: actualRoot)

    XCTAssertThrowsError(
      try CloudAttachmentCacheFiles.validatedChild(relativePath: "record/payload", root: symlinkRoot)
    ) { error in
      XCTAssertEqual(error as? CloudAttachmentStorageError, .symbolicLinkRoot)
    }
  }

  func testContainmentRejectsCanonicalSiblingOfAliasedRoot() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let actualRoot = root.appendingPathComponent("ActualCache", isDirectory: true)
    let aliasedRoot = root.appendingPathComponent("CacheAlias", isDirectory: true)
    let outside = root.appendingPathComponent("ActualCacheSibling", isDirectory: true)
    try FileManager.default.createDirectory(at: actualRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: aliasedRoot,
      withDestinationURL: actualRoot
    )

    XCTAssertThrowsError(
      try CloudAttachmentCacheFiles.requireChild(
        outside.appendingPathComponent("payload"),
        of: aliasedRoot
      )
    ) { error in
      XCTAssertEqual(error as? CloudAttachmentStorageError, .pathOutsideRoot)
    }
  }

  func testContainmentRejectsTraversalFromAReceiptURL() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let stagingRoot = root.appendingPathComponent("Staging", isDirectory: true)
    let traversal = stagingRoot.appendingPathComponent("../outside")

    XCTAssertThrowsError(
      try CloudAttachmentCacheFiles.requireChild(traversal, of: stagingRoot)
    ) { error in
      XCTAssertEqual(error as? CloudAttachmentStorageError, .pathOutsideRoot)
    }
  }

  func testCacheInstallStillRejectsSymlinkDestinationDescendant() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = CloudAttachmentCacheFiles(
      attachmentRootURL: root.appendingPathComponent("Attachments", isDirectory: true),
      lockURL: root.appendingPathComponent("snips.store.lock", isDirectory: false)
    )
    let namespace = "symlink-destination-descendant"
    let stagingRoot = try files.stagingRoot(namespaceKey: namespace)
    let staged = stagingRoot.appendingPathComponent("cloud-asset")
    try Data("downloaded bytes".utf8).write(to: staged)
    let cacheRoot = try files.cacheRoot(namespaceKey: namespace)
    let filesRoot = cacheRoot.appendingPathComponent("Files", isDirectory: true)
    let outside = root.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let aliasedDirectoryName = UUID().uuidString.lowercased()
    try FileManager.default.createSymbolicLink(
      at: filesRoot.appendingPathComponent(aliasedDirectoryName, isDirectory: true),
      withDestinationURL: outside
    )

    XCTAssertThrowsError(
      try files.installStagedFile(
        staged,
        namespaceKey: namespace,
        relativePath: "Files/\(aliasedDirectoryName)/payload"
      )
    ) { error in
      XCTAssertEqual(error as? CloudAttachmentStorageError, .symbolicLinkDescendant)
    }
  }

  func testStagedFileValidationStillRejectsSymlinkLeaf() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = CloudAttachmentCacheFiles(
      attachmentRootURL: root.appendingPathComponent("Attachments", isDirectory: true),
      lockURL: root.appendingPathComponent("snips.store.lock", isDirectory: false)
    )
    let namespace = "symlink-leaf"
    let stagingRoot = try files.stagingRoot(namespaceKey: namespace)
    let bytes = Data("outside bytes".utf8)
    let outside = root.appendingPathComponent("outside")
    try bytes.write(to: outside)
    let staged = stagingRoot.appendingPathComponent("cloud-asset")
    try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: outside)

    XCTAssertThrowsError(
      try files.validateStagedFile(
        staged,
        namespaceKey: namespace,
        expectedByteCount: Int64(bytes.count),
        expectedSHA256: Data(SHA256.hash(data: bytes))
      )
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudAttachmentStorageTests-\(UUID().uuidString)", isDirectory: true)
  }
}
