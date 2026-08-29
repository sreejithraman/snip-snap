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
      namespaceKey: "namespace-generation-a",
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let firstSnapshot = try await library?.cloudAttachmentStorageSnapshot(
      namespaceKey: "namespace-generation-a"
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
      namespaceKey: "namespace-generation-a",
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let secondSnapshot = try await reopened.cloudAttachmentStorageSnapshot(
      namespaceKey: "namespace-generation-a"
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
    for namespace in ["generation-a", "generation-b"] {
      try await library.reconcileCloudAttachments(
        namespaceKey: namespace,
        metadataZoneName: "data",
        metadataOwnerName: "owner",
        payloadZoneName: "payload",
        payloadOwnerName: "owner"
      )
    }
    let a = try await library.cloudAttachmentStorageSnapshot(namespaceKey: "generation-a")
    let b = try await library.cloudAttachmentStorageSnapshot(namespaceKey: "generation-b")
    XCTAssertEqual(a.publications.map(\.metadata.attachmentID), b.publications.map(\.metadata.attachmentID))
    XCTAssertNotEqual(a.publications.first?.metadata.payloadIdentity, b.publications.first?.metadata.payloadIdentity)
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
      namespaceKey: "namespace",
      transitions: [.remoteMetadataAccepted(
        metadata: metadata(firstPayload, hashByte: 1),
        metadataIdentity: metadataIdentity,
        shadowData: Data("shadow-1".utf8),
        systemFields: Data("fields-1".utf8)
      )]
    )
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: "namespace",
      transitions: [.remoteMetadataAccepted(
        metadata: metadata(secondPayload, hashByte: 2),
        metadataIdentity: metadataIdentity,
        shadowData: Data("shadow-2".utf8),
        systemFields: Data("fields-2".utf8)
      )]
    )

    let stored = try await library.cloudAttachmentStorageSnapshot(namespaceKey: "namespace")
    XCTAssertEqual(stored.publications.first?.metadata.payloadIdentity, secondPayload)
    XCTAssertEqual(stored.publications.first?.metadata.sha256, Data(repeating: 2, count: 32))
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudAttachmentStorageTests-\(UUID().uuidString)", isDirectory: true)
  }
}
