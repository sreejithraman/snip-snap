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

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudAttachmentStorageTests-\(UUID().uuidString)", isDirectory: true)
  }
}
