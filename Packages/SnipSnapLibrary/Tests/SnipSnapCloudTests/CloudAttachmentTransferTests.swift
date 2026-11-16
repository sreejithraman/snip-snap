import CloudKit
import CryptoKit
import Foundation
import SnipSnapCore
import SwiftData
import Testing
import XCTest

@testable import SnipSnapCloud
@testable import SnipSnapPersistence

final class CloudAttachmentTransferTests: XCTestCase, AttachmentTransferTestSupport {
  func testNormalSyncPublishesPayloadBeforeMetadataAndRemoteClientSeesAttachment() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let server = FakeCloudServer()
    let source = root.appendingPathComponent("local-first.txt")
    let bytes = Data("saved before the network".utf8)
    try bytes.write(to: source)
    let senderLibrary = try SwiftDataSnipLibrary(
      storeURL: root.appendingPathComponent("sender.store")
    )
    let update = try await senderLibrary.perform(
      .add(
        content: "with an attachment",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = update.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let senderStore = CloudFullSyncPersistence(
      library: senderLibrary,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    try await senderStore.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let sender = CloudFullSyncCoordinator(
      store: senderStore,
      transport: FakeCloudRecordTransport(
        server: server,
        namespace: namespace,
        automaticallyFetchedZones: [dataZone]
      ),
      fetchScope: .zones([dataZone])
    )

    try await sender.sync()

    let afterPayload = try await snapshot(senderLibrary, namespace)
    let publication = try XCTUnwrap(afterPayload.publications.first)
    XCTAssertTrue(publication.payloadAccepted)
    XCTAssertFalse(publication.metadataAccepted)
    let payloadCount = await server.acceptedOperationCount(
      for: CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity)
    )
    let metadataCount = await server.acceptedOperationCount(
      for: CloudAttachmentRecordCodec.recordID(publication.metadataIdentity)
    )
    XCTAssertEqual(payloadCount, 1)
    XCTAssertEqual(metadataCount, 0)

    try await sender.sync()

    let afterMetadata = try await snapshot(senderLibrary, namespace)
    XCTAssertTrue(try XCTUnwrap(afterMetadata.publications.first).metadataAccepted)
    let receiverLibrary = try SwiftDataSnipLibrary(
      storeURL: root.appendingPathComponent("receiver.store")
    )
    let receiverStore = CloudFullSyncPersistence(
      library: receiverLibrary,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    let receiverTransport = FakeCloudRecordTransport(
      server: server,
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    let receiver = CloudFullSyncCoordinator(
      store: receiverStore,
      transport: receiverTransport,
      fetchScope: .zones([dataZone])
    )
    try await receiver.fetchRemote()

    let received = try await receiverLibrary.checkedSnapshot(sortedBy: .manual)
    let receivedSnip = try XCTUnwrap(received.snips.first(where: { $0.id == snipID }))
    XCTAssertEqual(receivedSnip.attachments.map(\.fileName), ["local-first.txt"])
    let receivedAttachmentID = try XCTUnwrap(receivedSnip.attachments.first).id
    XCTAssertNil(received.attachmentURLs[receivedAttachmentID])
    let downloads = CloudAttachmentTransferCoordinator(
      library: receiverLibrary,
      namespace: namespace,
      payloadZone: payloadZone,
      transport: receiverTransport,
      maximumCacheBytes: 1024
    )
    let downloaded = try await downloads.download(attachmentID: receivedAttachmentID)
    XCTAssertEqual(try Data(contentsOf: downloaded), bytes)

    try await receiver.fetchRemote()

    let afterLaterSync = try await receiverLibrary.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(afterLaterSync.attachmentURLs[receivedAttachmentID], downloaded)
  }

  func testQuotaUploadFailureDoesNotFalseAcceptBeforeRetry() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let source = root.appendingPathComponent("offline.txt")
    let bytes = Data("local save survives".utf8)
    try bytes.write(to: source)
    let storeURL = root.appendingPathComponent("store")
    var library: SwiftDataSnipLibrary? = try SwiftDataSnipLibrary(storeURL: storeURL)
    let update = try await library?.perform(
      .add(
        content: "offline",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = update?.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let server = FakeCloudServer()
    let offline = FakeCloudRecordTransport(
      server: server,
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    let firstStore = CloudFullSyncPersistence(
      library: try XCTUnwrap(library),
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    try await firstStore.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    _ = try await firstStore.pendingChanges()
    let beforeFailure = try await snapshot(try XCTUnwrap(library), namespace)
    let queuedPublication = try XCTUnwrap(beforeFailure.publications.first)
    await offline.failNextSentItem(
      CloudAttachmentRecordCodec.recordID(queuedPublication.metadata.payloadIdentity),
      failure: .quotaExceeded
    )
    let first = CloudFullSyncCoordinator(
      store: firstStore,
      transport: offline,
      fetchScope: .zones([dataZone])
    )
    try await first.sendPending()

    let savedLocally = try await library?.checkedSnapshot(sortedBy: .manual)
    let attachmentID = try XCTUnwrap(savedLocally?.snips.first?.attachments.first?.id)
    let localURL = try XCTUnwrap(savedLocally?.attachmentURLs[attachmentID])
    XCTAssertEqual(try Data(contentsOf: localURL), bytes)
    let queued = try await snapshot(try XCTUnwrap(library), namespace)
    XCTAssertEqual(queued.publications.first?.transferState, .failed(.quotaExceeded))
    XCTAssertFalse(try XCTUnwrap(queued.publications.first).metadataAccepted)
    let failedPayloadCount = await server.acceptedOperationCount(
      for: CloudAttachmentRecordCodec.recordID(queuedPublication.metadata.payloadIdentity)
    )
    XCTAssertEqual(failedPayloadCount, 0)
    let durableUpload = try XCTUnwrap(queued.publications.first?.sourceURL)
    XCTAssertNotEqual(durableUpload.standardizedFileURL, localURL.standardizedFileURL)
    XCTAssertEqual(try Data(contentsOf: durableUpload), bytes)

    library = nil
    let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)
    let resumedStore = CloudFullSyncPersistence(
      library: reopened,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    let resumed = CloudFullSyncCoordinator(
      store: resumedStore,
      transport: FakeCloudRecordTransport(
        server: server,
        namespace: namespace,
        automaticallyFetchedZones: [dataZone]
      ),
      fetchScope: .zones([dataZone])
    )
    try await resumed.sync()
    let automaticRetryCount = await server.acceptedOperationCount(
      for: CloudAttachmentRecordCodec.recordID(queuedPublication.metadata.payloadIdentity)
    )
    let automaticallyRetried = try await snapshot(reopened, namespace)
    XCTAssertEqual(automaticRetryCount, 0)
    XCTAssertEqual(
      automaticallyRetried.publications.first?.transferState,
      .failed(.quotaExceeded)
    )

    try await resumedStore.prepareManualRetry()
    try await resumed.sync()
    try await resumed.sync()

    let settled = try await snapshot(reopened, namespace)
    XCTAssertTrue(try XCTUnwrap(settled.publications.first).metadataAccepted)
    let retriedPayloadCount = await server.acceptedOperationCount(
      for: CloudAttachmentRecordCodec.recordID(queuedPublication.metadata.payloadIdentity)
    )
    XCTAssertEqual(retriedPayloadCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: durableUpload.path))
  }

  func testInterruptedUploadRetriesWithoutDuplicateAcceptance() async throws {
    let fixture = try await makePendingAttachmentFixture(names: ["interrupted"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.store.approveEnrollment(references: [])
    let initial = try await snapshot(fixture.library, fixture.namespace)
    let publication = try XCTUnwrap(initial.publications.first)
    let payloadID = CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity)
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(
      server: server,
      namespace: fixture.namespace,
      automaticallyFetchedZones: [CloudZoneID(name: "data", ownerName: "owner")]
    )
    await transport.failNextSentItem(payloadID, failure: .retryable)
    let coordinator = CloudFullSyncCoordinator(
      store: fixture.store,
      transport: transport,
      fetchScope: .zones([CloudZoneID(name: "data", ownerName: "owner")])
    )

    try await coordinator.sendPending()

    let interrupted = try await snapshot(fixture.library, fixture.namespace)
    XCTAssertFalse(try XCTUnwrap(interrupted.publications.first).metadataAccepted)
    let interruptedCount = await server.acceptedOperationCount(for: payloadID)
    XCTAssertEqual(interruptedCount, 0)

    let retry = try await coordinator.sendPendingUntilSettled()

    let settled = try await snapshot(fixture.library, fixture.namespace)
    XCTAssertTrue(try XCTUnwrap(settled.publications.first).metadataAccepted)
    XCTAssertTrue(retry.settled)
    let settledCount = await server.acceptedOperationCount(for: payloadID)
    XCTAssertEqual(settledCount, 1)
  }

  func testReplacementPublishesNewPayloadAndMetadataBeforeDeletingOldPayload() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let server = FakeCloudServer()
    let source = root.appendingPathComponent("first.txt")
    try Data("first".utf8).write(to: source)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "replace",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let attachmentID = try XCTUnwrap(added.snapshot.snips.first?.attachments.first?.id)
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    try await store.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let sync = CloudFullSyncCoordinator(
      store: store,
      transport: FakeCloudRecordTransport(
        server: server,
        namespace: namespace,
        automaticallyFetchedZones: [dataZone]
      ),
      fetchScope: .zones([dataZone])
    )
    try await sync.sync()
    try await sync.sync()
    let firstStorage = try await snapshot(library, namespace)
    let firstPublication = try XCTUnwrap(firstStorage.publications.first)
    let oldPayloadID = CloudAttachmentRecordCodec.recordID(
      firstPublication.metadata.payloadIdentity
    )

    let replacement = root.appendingPathComponent("second.txt")
    try Data("second payload".utf8).write(to: replacement)
    let currentSnapshot = try await library.checkedSnapshot(sortedBy: .manual)
    let current = try XCTUnwrap(currentSnapshot.snips.first)
    _ = try await library.perform(
      .editAttachments(
        snipID: snipID,
        content: current.content,
        edits: [.replacement(attachmentID: attachmentID, sourceURL: replacement)],
        expectedUpdatedAt: current.updatedAt,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )
    let replacedSnapshot = try await library.checkedSnapshot(sortedBy: .manual)
    let replacementAttachmentID = try XCTUnwrap(
      replacedSnapshot.snips.first?.attachments.first?.id
    )
    XCTAssertNotEqual(replacementAttachmentID, attachmentID)

    try await sync.sync()

    let payloadStorage = try await snapshot(library, namespace)
    let payloadAccepted = try XCTUnwrap(payloadStorage.publications.first(where: {
      $0.metadata.attachmentID == replacementAttachmentID
    }))
    let newPayloadID = CloudAttachmentRecordCodec.recordID(
      payloadAccepted.metadata.payloadIdentity
    )
    XCTAssertNotEqual(newPayloadID, oldPayloadID)
    let oldAfterPayload = await server.fullSnapshot(for: oldPayloadID)
    let newAfterPayload = await server.fullSnapshot(for: newPayloadID)
    XCTAssertNotNil(oldAfterPayload)
    XCTAssertNotNil(newAfterPayload)
    XCTAssertFalse(payloadAccepted.metadataAccepted)

    try await sync.sync()

    let metadataAccepted = try await snapshot(library, namespace)
    XCTAssertTrue(try XCTUnwrap(metadataAccepted.publications.first(where: {
      $0.metadata.attachmentID == replacementAttachmentID
    })).metadataAccepted)
    XCTAssertEqual(
      metadataAccepted.cleanups.map(\.identity),
      [firstPublication.metadata.payloadIdentity]
    )
    let oldAfterMetadata = await server.fullSnapshot(for: oldPayloadID)
    XCTAssertNotNil(oldAfterMetadata)

    try await sync.sync()

    let afterMetadataDeletion = try await snapshot(library, namespace)
    XCTAssertTrue(afterMetadataDeletion.cleanups.isEmpty)
    let oldAfterMetadataDeletion = await server.fullSnapshot(for: oldPayloadID)
    XCTAssertNil(oldAfterMetadataDeletion)
    let newAfterCleanup = await server.fullSnapshot(for: newPayloadID)
    let finalStorage = try await snapshot(library, namespace)
    XCTAssertNotNil(newAfterCleanup)
    XCTAssertTrue(finalStorage.cleanups.isEmpty)
  }

  func testMetadataConflictRetriesFromServerShadowAndKeepsUnknownFields() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let first = root.appendingPathComponent("first.txt")
    let second = root.appendingPathComponent("second.txt")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let update = try await library.perform(
      .add(
        content: "two",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [first, second],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = update.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(
      server: server,
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    try await store.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let sync = CloudFullSyncCoordinator(
      store: store,
      transport: transport,
      fetchScope: .zones([dataZone])
    )
    try await sync.sync()
    try await sync.sync()

    let initial = try await snapshot(library, namespace)
    let target = try XCTUnwrap(initial.publications.first)
    let metadataID = CloudAttachmentRecordCodec.recordID(target.metadataIdentity)
    let fetchedServerRecord = await server.fullSnapshot(for: metadataID)
    let serverRecord = try XCTUnwrap(fetchedServerRecord)
    var externalFields = serverRecord.encryptedFields
    externalFields["futureClientField"] = .string("keep me")
    let externalDraft = CloudRecordDraft(
      id: metadataID,
      recordType: serverRecord.recordType,
      schemaVersion: serverRecord.schemaVersion,
      routingFields: serverRecord.routingFields,
      encryptedFields: externalFields,
      base: serverRecord.shadow
    )
    let external = FakeCloudRecordTransport(server: server, namespace: namespace)
    let externalResult = try await external.send(CloudOutboundBatch(operations: [.save(externalDraft)]))
    try await external.confirmApplied(externalResult.id)

    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == snipID }))
    _ = try await library.perform(
      .editAttachments(
        snipID: snipID,
        content: snip.content,
        edits: snip.attachments.reversed().map { .existing(attachmentID: $0.id) },
        expectedUpdatedAt: snip.updatedAt,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )

    try await sync.sendPending()
    let conflicted = try await snapshot(library, namespace)
    XCTAssertFalse(try XCTUnwrap(conflicted.publications.first(where: {
      $0.metadata.attachmentID == target.metadata.attachmentID
    })).metadataAccepted)

    try await sync.sendPending()
    let settled = try await snapshot(library, namespace)
    XCTAssertTrue(try XCTUnwrap(settled.publications.first(where: {
      $0.metadata.attachmentID == target.metadata.attachmentID
    })).metadataAccepted)
    let fetchedFinalServer = await server.fullSnapshot(for: metadataID)
    let finalServer = try XCTUnwrap(fetchedFinalServer)
    XCTAssertEqual(finalServer.encryptedFields["futureClientField"], .string("keep me"))
  }

  func testMetadataSaveAfterRemoteDeleteUsesNewAttachmentIdentity() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let first = root.appendingPathComponent("first.txt")
    let second = root.appendingPathComponent("second.txt")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let update = try await library.perform(
      .add(
        content: "remote delete race",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [first, second],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = update.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(
      server: server,
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    try await store.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let sync = CloudFullSyncCoordinator(
      store: store,
      transport: transport,
      fetchScope: .zones([dataZone])
    )
    try await sync.sync()
    try await sync.sync()
    let initial = try await snapshot(library, namespace)
    let target = try XCTUnwrap(initial.publications.first(where: {
      $0.metadata.fileName == "first.txt"
    }))
    let oldAttachmentID = target.metadata.attachmentID
    let oldMetadataID = CloudAttachmentRecordCodec.recordID(target.metadataIdentity)
    let payloadIdentity = target.metadata.payloadIdentity
    let fetchedServerMetadata = await server.fullSnapshot(for: oldMetadataID)
    let serverMetadata = try XCTUnwrap(fetchedServerMetadata)
    let secondClient = FakeCloudRecordTransport(server: server, namespace: namespace)
    let deleted = try await secondClient.send(CloudOutboundBatch(operations: [
      .delete(oldMetadataID, base: serverMetadata.shadow)
    ]))
    try await secondClient.confirmApplied(deleted.id)

    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == snipID }))
    _ = try await library.perform(
      .editAttachments(
        snipID: snipID,
        content: snip.content,
        edits: snip.attachments.reversed().map { .existing(attachmentID: $0.id) },
        expectedUpdatedAt: snip.updatedAt,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )

    try await sync.sendPending()

    let recovered = try await snapshot(library, namespace)
    let replacement = try XCTUnwrap(recovered.publications.first(where: {
      $0.metadata.fileName == target.metadata.fileName
    }))
    XCTAssertNotEqual(replacement.metadata.attachmentID, oldAttachmentID)
    XCTAssertNotEqual(replacement.metadataIdentity, target.metadataIdentity)
    XCTAssertNotEqual(replacement.metadata.payloadIdentity, payloadIdentity)
    XCTAssertFalse(replacement.payloadAccepted)
    XCTAssertFalse(replacement.metadataAccepted)
    XCTAssertEqual(recovered.cleanups.count, 1)
    XCTAssertEqual(recovered.cleanups.first?.identity, payloadIdentity)
    XCTAssertEqual(recovered.cleanups.first?.blockedByAttachmentID, replacement.metadata.attachmentID)
    let domain = try await library.checkedSnapshot(sortedBy: .manual)
    let domainSnip = try XCTUnwrap(domain.snips.first(where: { $0.id == snipID }))
    XCTAssertFalse(domainSnip.attachments.contains(where: { $0.id == oldAttachmentID }))
    XCTAssertTrue(domainSnip.attachments.contains(where: {
      $0.id == replacement.metadata.attachmentID
    }))

    try await sync.sendPending()
    try await sync.sendPending()

    let settled = try await snapshot(library, namespace)
    XCTAssertTrue(try XCTUnwrap(settled.publications.first(where: {
      $0.metadata.attachmentID == replacement.metadata.attachmentID
    })).metadataAccepted)
    let oldMetadata = await server.fullSnapshot(for: oldMetadataID)
    XCTAssertNil(oldMetadata)
    let newMetadata = await server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(replacement.metadataIdentity)
    )
    XCTAssertEqual(
      newMetadata?.encryptedFields["payloadRecordName"],
      .string(replacement.metadata.payloadIdentity.recordName)
    )
    let newPayload = await server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(replacement.metadata.payloadIdentity)
    )
    XCTAssertNotNil(newPayload)

    try await sync.sendPending()

    let oldPayload = await server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(payloadIdentity)
    )
    XCTAssertNil(oldPayload)
    let cleaned = try await snapshot(library, namespace)
    XCTAssertEqual(cleaned.cleanups, [])
  }

  func testPayloadUnknownItemRetriesWithANewOpaquePayloadIdentity() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("payload-race.txt")
    try Data("payload race".utf8).write(to: source)
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let update = try await library.perform(
      .add(
        content: "payload unknown race",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = update.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    try await store.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let outbound = try await store.pendingChanges()
    let payloadDraft = try XCTUnwrap(outbound.operations.compactMap { operation -> CloudRecordDraft? in
      guard case .save(let draft) = operation,
        draft.recordType == CloudAttachmentRecordCodec.payloadRecordType
      else { return nil }
      return draft
    }.first)
    let results = outbound.operations.map { operation -> CloudSendItemResult in
      operation.id == payloadDraft.id
        ? .unknownItem(operation.id)
        : .failed(operation.id, .retryable)
    }
    let sent = CloudSentBatch(id: UUID(), items: results, engineState: nil)

    try await store.stage(.sent(sent), outbound: outbound)
    try await store.applyStaged(sent.id)

    let after = try await snapshot(library, namespace)
    let publication = try XCTUnwrap(after.publications.first)
    XCTAssertNotEqual(
      CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity),
      payloadDraft.id
    )
    XCTAssertFalse(publication.payloadAccepted)
    XCTAssertFalse(publication.metadataAccepted)
    let retry = try await store.pendingChanges()
    let replacementPayloadID = CloudAttachmentRecordCodec.recordID(
      publication.metadata.payloadIdentity
    )
    XCTAssertFalse(retry.operations.contains { $0.id == payloadDraft.id })
    XCTAssertTrue(retry.operations.contains { $0.id == replacementPayloadID })
    XCTAssertFalse(retry.operations.contains { operation in
      guard case .save(let draft) = operation else { return false }
      return draft.recordType == CloudAttachmentRecordCodec.metadataRecordType
    })

    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(
      server: server,
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    let sync = CloudFullSyncCoordinator(
      store: store,
      transport: transport,
      fetchScope: .zones([dataZone])
    )
    try await sync.sendPending()

    let afterPayload = try await snapshot(library, namespace)
    let payloadAccepted = try XCTUnwrap(afterPayload.publications.first)
    XCTAssertTrue(payloadAccepted.payloadAccepted)
    XCTAssertFalse(payloadAccepted.metadataAccepted)
    let metadataBatch = try await store.pendingChanges()
    let metadataDraft = try XCTUnwrap(metadataBatch.operations.compactMap {
      operation -> CloudRecordDraft? in
      guard case .save(let draft) = operation,
        draft.recordType == CloudAttachmentRecordCodec.metadataRecordType
      else { return nil }
      return draft
    }.first)
    XCTAssertEqual(
      metadataDraft.encryptedFields["payloadRecordName"],
      .string(replacementPayloadID.name)
    )

    try await sync.sendPending()
    let settled = try await snapshot(library, namespace)
    XCTAssertTrue(try XCTUnwrap(settled.publications.first).metadataAccepted)
  }

  func testTerminalPayloadFailureDoesNotStarveAnotherAttachmentMetadata() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first.txt")
    let second = root.appendingPathComponent("second.txt")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "fair send",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [first, second],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(
      server: server,
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    try await store.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    _ = try await store.pendingChanges()
    let initial = try await snapshot(library, namespace)
    let ordered = initial.publications.sorted {
      $0.metadata.fileName < $1.metadata.fileName
    }
    let failed = try XCTUnwrap(ordered.first)
    let successful = try XCTUnwrap(ordered.last)
    await transport.failNextSentItem(
      CloudAttachmentRecordCodec.recordID(failed.metadata.payloadIdentity),
      failure: .rejected
    )
    let sync = CloudFullSyncCoordinator(
      store: store,
      transport: transport,
      fetchScope: .zones([dataZone])
    )

    try await sync.sendPending()
    try await sync.sendPending()

    let after = try await snapshot(library, namespace)
    XCTAssertEqual(
      after.publications.first(where: { $0.metadata.attachmentID == failed.metadata.attachmentID })?
        .transferState,
      .failed(.rejected)
    )
    XCTAssertTrue(try XCTUnwrap(after.publications.first(where: {
      $0.metadata.attachmentID == successful.metadata.attachmentID
    })).metadataAccepted)
    let automaticResult = try await sync.processAutomaticChanges().result
    XCTAssertEqual(automaticResult, .syncIssue(.appDataIssue))
    let unresolvedIssue = try await store.unresolvedSyncIssue()
    XCTAssertEqual(unresolvedIssue, .appDataIssue)
  }

  func testTerminalAttachmentIssueKeepsExactPriorityAfterReopen() async throws {
    let cases: [(CloudOperationFailure, SyncedContentSyncIssue)] = [
      (.quotaExceeded, .iCloudStorageFull),
      (.updateRequired, .updateRequired),
      (.accessDenied, .accessDenied),
      (.attachmentMissing, .attachmentMissing),
      (.rejected, .appDataIssue),
    ]
    for (failure, expectedIssue) in cases {
      let fixture = try await makePendingAttachmentFixture(names: ["terminal", "retryable"])
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let publications = try await snapshot(fixture.library, fixture.namespace).publications.sorted {
        $0.metadata.fileName < $1.metadata.fileName
      }
      let retryable = try XCTUnwrap(publications.first)
      let terminal = try XCTUnwrap(publications.last)
      let server = FakeCloudServer()
      let transport = FakeCloudRecordTransport(
        server: server,
        namespace: fixture.namespace,
        automaticallyFetchedZones: [CloudZoneID(name: "data", ownerName: "owner")]
      )
      await transport.failNextSentItem(
        CloudAttachmentRecordCodec.recordID(retryable.metadata.payloadIdentity),
        failure: .retryable
      )
      await transport.failNextSentItem(
        CloudAttachmentRecordCodec.recordID(terminal.metadata.payloadIdentity),
        failure: failure
      )
      let sync = CloudFullSyncCoordinator(
        store: fixture.store,
        transport: transport,
        fetchScope: .zones([CloudZoneID(name: "data", ownerName: "owner")])
      )

      try await sync.sendPending()

      let mixedIssue = try await fixture.store.unresolvedSyncIssue()
      XCTAssertEqual(mixedIssue, expectedIssue, "Wrong mixed-failure priority for \(failure)")
      let reopenedLibrary = try SwiftDataSnipLibrary(
        storeURL: fixture.root.appendingPathComponent("store")
      )
      let reopenedStore = CloudFullSyncPersistence(
        library: reopenedLibrary,
        namespace: fixture.namespace,
        dataZone: CloudZoneID(name: "data", ownerName: "owner"),
        payloadZone: CloudZoneID(name: "payload", ownerName: "owner")
      )
      _ = try await reopenedStore.clearRetryableRecoveryEvents(kind: .retryableSend)
      let reopenedIssue = try await reopenedStore.unresolvedSyncIssue()
      XCTAssertEqual(reopenedIssue, expectedIssue, "Lost issue after reopen for \(failure)")
      let retryableID = CloudAttachmentRecordCodec.recordID(
        retryable.metadata.payloadIdentity
      )
      let terminalID = CloudAttachmentRecordCodec.recordID(
        terminal.metadata.payloadIdentity
      )
      let pending = try await reopenedStore.pendingChanges()
      let plannedAttachmentIDs = Set(pending.operations.map(\.id))
        .intersection([retryableID, terminalID])
      XCTAssertEqual(
        plannedAttachmentIDs,
        [retryableID],
        "Retried a terminal attachment failure for \(failure)"
      )
      try await reopenedStore.prepareManualRetry()
      let manualPending = try await reopenedStore.pendingChanges()
      let manualAttachmentIDs = Set(manualPending.operations.map(\.id))
        .intersection([retryableID, terminalID])
      let expectedManualIDs: Set<CloudRecordID> = switch failure {
      case .updateRequired, .accessDenied: [retryableID]
      default: [retryableID, terminalID]
      }
      XCTAssertEqual(
        manualAttachmentIDs,
        expectedManualIDs,
        "Manual retry policy was wrong for \(failure)"
      )
    }
  }

  func testPendingPayloadDoesNotDelayAnotherAttachmentMetadata() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first.txt")
    let second = root.appendingPathComponent("second.txt")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "independent stages",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [first, second],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    try await store.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    _ = try await store.pendingChanges()
    let initial = try await snapshot(library, namespace)
    let readyForMetadata = try XCTUnwrap(initial.publications.last)
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace.namespaceKey,
      transitions: [.payloadAccepted(
        attachmentID: readyForMetadata.metadata.attachmentID,
        expectedRevision: readyForMetadata.revision,
        shadowData: Data("payload-shadow".utf8),
        systemFields: Data("payload-fields".utf8)
      )]
    )

    let pending = try await store.pendingChanges()
    let recordTypes = Set(pending.operations.compactMap { operation -> String? in
      guard case .save(let draft) = operation else { return nil }
      return draft.recordType
    })

    XCTAssertTrue(recordTypes.contains(CloudAttachmentRecordCodec.payloadRecordType))
    XCTAssertTrue(recordTypes.contains(CloudAttachmentRecordCodec.metadataRecordType))
  }

  func testTerminalMetadataSaveDoesNotRetryOrBlockLaterDeleteAndCleanup() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first.txt")
    let second = root.appendingPathComponent("second.txt")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "metadata fairness",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [first, second],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(
      server: server,
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    try await store.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let sync = CloudFullSyncCoordinator(
      store: store,
      transport: transport,
      fetchScope: .zones([dataZone])
    )
    try await sync.sync()
    let payloadsAccepted = try await snapshot(library, namespace)
    let ordered = payloadsAccepted.publications.sorted {
      $0.metadata.fileName < $1.metadata.fileName
    }
    let failed = try XCTUnwrap(ordered.first)
    let removable = try XCTUnwrap(ordered.last)
    let failedMetadataID = CloudAttachmentRecordCodec.recordID(failed.metadataIdentity)
    let removablePayloadID = CloudAttachmentRecordCodec.recordID(
      removable.metadata.payloadIdentity
    )
    await transport.failNextSentItem(failedMetadataID, failure: .rejected)

    try await sync.sendPending()

    let afterFailure = try await snapshot(library, namespace)
    XCTAssertEqual(
      afterFailure.publications.first(where: {
        $0.metadata.attachmentID == failed.metadata.attachmentID
      })?.lastFailure,
      .rejected
    )
    XCTAssertTrue(afterFailure.publications.first(where: {
      $0.metadata.attachmentID == removable.metadata.attachmentID
    })?.metadataAccepted == true)
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == snipID }))
    _ = try await library.perform(
      .editAttachments(
        snipID: snipID,
        content: snip.content,
        edits: [.existing(attachmentID: failed.metadata.attachmentID)],
        expectedUpdatedAt: snip.updatedAt,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )

    try await sync.sendPending()
    try await sync.sendPending()

    let removedPayload = await server.fullSnapshot(for: removablePayloadID)
    XCTAssertNil(removedPayload)
    let failedMetadataSends = await transport.events().compactMap { event -> [CloudRecordID]? in
      guard case .sent(let ids) = event else { return nil }
      return ids
    }.flatMap { $0 }.filter { $0 == failedMetadataID }
    XCTAssertEqual(failedMetadataSends.count, 1)
  }

  func testCorruptMetadataSaveShadowQuarantinesOnlyThatPublication() async throws {
    let fixture = try await makePendingAttachmentFixture(names: ["bad", "good"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let initial = try await snapshot(fixture.library, fixture.namespace)
    let ordered = initial.publications.sorted { $0.metadata.fileName < $1.metadata.fileName }
    let bad = try XCTUnwrap(ordered.first)
    let good = try XCTUnwrap(ordered.last)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: ordered.map {
        .payloadAccepted(
          attachmentID: $0.metadata.attachmentID,
          expectedRevision: $0.revision,
          shadowData: Data("payload-shadow".utf8),
          systemFields: Data()
        )
      }
    )
    let payloadAccepted = try await snapshot(fixture.library, fixture.namespace)
    let badReady = try XCTUnwrap(payloadAccepted.publications.first(where: {
      $0.metadata.attachmentID == bad.metadata.attachmentID
    }))
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.metadataConflict(
        attachmentID: badReady.metadata.attachmentID,
        expectedRevision: badReady.revision,
        shadowData: Data("not-a-cloud-record-shadow".utf8),
        systemFields: Data()
      )]
    )

    let pending = try await fixture.store.pendingChanges()

    XCTAssertTrue(pending.operations.contains(where: {
      $0.id == CloudAttachmentRecordCodec.recordID(good.metadataIdentity)
    }))
    XCTAssertFalse(pending.operations.contains(where: {
      $0.id == CloudAttachmentRecordCodec.recordID(bad.metadataIdentity)
    }))
    let after = try await snapshot(fixture.library, fixture.namespace)
    XCTAssertEqual(after.publications.first(where: {
      $0.metadata.attachmentID == bad.metadata.attachmentID
    })?.lastFailure, .invalidRecord)
  }

  func testCorruptMetadataDeleteShadowQuarantinesOnlyThatPublication() async throws {
    let fixture = try await makePendingAttachmentFixture(names: ["bad", "good"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let initial = try await snapshot(fixture.library, fixture.namespace)
    let ordered = initial.publications.sorted { $0.metadata.fileName < $1.metadata.fileName }
    let bad = try XCTUnwrap(ordered.first)
    let good = try XCTUnwrap(ordered.last)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.remoteMetadataAccepted(
        metadata: bad.metadata,
        metadataIdentity: bad.metadataIdentity,
        shadowData: Data("not-a-cloud-record-shadow".utf8),
        systemFields: Data()
      )]
    )
    let local = try await fixture.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first)
    _ = try await fixture.library.perform(
      .editAttachments(
        snipID: snip.id,
        content: snip.content,
        edits: [.existing(attachmentID: good.metadata.attachmentID)],
        expectedUpdatedAt: snip.updatedAt,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )

    let pending = try await fixture.store.pendingChanges()

    XCTAssertTrue(pending.operations.contains(where: {
      $0.id == CloudAttachmentRecordCodec.recordID(good.metadata.payloadIdentity)
    }))
    XCTAssertFalse(pending.operations.contains(where: {
      $0.id == CloudAttachmentRecordCodec.recordID(bad.metadataIdentity)
    }))
    let after = try await snapshot(fixture.library, fixture.namespace)
    XCTAssertEqual(after.publications.first(where: {
      $0.metadata.attachmentID == bad.metadata.attachmentID
    })?.lastFailure, .invalidRecord)
  }

  func testCorruptCleanupShadowQuarantinesOnlyThatCleanup() async throws {
    let fixture = try await makePendingAttachmentFixture(names: ["removed"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let initial = try await snapshot(fixture.library, fixture.namespace)
    let publication = try XCTUnwrap(initial.publications.first)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.payloadAccepted(
        attachmentID: publication.metadata.attachmentID,
        expectedRevision: publication.revision,
        shadowData: Data("not-a-cloud-record-shadow".utf8),
        systemFields: Data()
      )]
    )
    let payloadAccepted = try await snapshot(fixture.library, fixture.namespace)
    let readyForMetadata = try XCTUnwrap(payloadAccepted.publications.first)
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(server: server, namespace: fixture.namespace)
    let sent = try await transport.send(CloudOutboundBatch(operations: [
      .save(try CloudAttachmentRecordCodec.metadataDraft(readyForMetadata))
    ]))
    guard case .saved(let metadataSnapshot) = try XCTUnwrap(sent.items.first) else {
      return XCTFail("Expected metadata save")
    }
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.metadataAccepted(
        attachmentID: readyForMetadata.metadata.attachmentID,
        expectedRevision: readyForMetadata.revision,
        shadowData: metadataSnapshot.shadow.data,
        systemFields: metadataSnapshot.shadow.systemFields
      )]
    )
    let local = try await fixture.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first)
    _ = try await fixture.library.perform(
      .editAttachments(
        snipID: snip.id,
        content: snip.content,
        edits: [],
        expectedUpdatedAt: snip.updatedAt,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )
    _ = try await fixture.store.pendingChanges()
    let removed = try await snapshot(fixture.library, fixture.namespace)
    let deletion = try XCTUnwrap(removed.publications.first)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.metadataDeleteAccepted(
        attachmentID: deletion.metadata.attachmentID,
        expectedRevision: deletion.revision
      )]
    )
    let unrelatedURL = fixture.root.appendingPathComponent("unrelated.txt")
    try Data("unrelated payload".utf8).write(to: unrelatedURL)
    _ = try await fixture.library.perform(
      .add(
        content: "unrelated",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [unrelatedURL],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 3)
      ),
      sortedBy: .manual
    )

    let pending = try await fixture.store.pendingChanges()

    XCTAssertTrue(pending.operations.contains(where: { operation in
      guard case .save(let draft) = operation else { return false }
      return draft.recordType == CloudAttachmentRecordCodec.payloadRecordType
    }))
    XCTAssertFalse(pending.operations.contains(where: {
      $0.id == CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity)
    }))
    let after = try await snapshot(fixture.library, fixture.namespace)
    XCTAssertEqual(after.cleanups.first(where: {
      $0.identity == publication.metadata.payloadIdentity
    })?.lastFailure, .invalidRecord)
  }

  func testMetadataIdentityRemapUpdatesReplacementCleanupDependencyInSameBatch() async throws {
    let fixture = try await makePendingAttachmentFixture(names: ["replacement"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let initial = try await snapshot(fixture.library, fixture.namespace)
    let replacement = try XCTUnwrap(initial.publications.first)
    let deletedAttachmentID = UUID()
    let deletedMetadataIdentity = CloudTextStorageIdentity(
      zoneName: "data",
      ownerName: "owner",
      recordName: "a-\(deletedAttachmentID.uuidString.lowercased())"
    )
    let deletedPayloadIdentity = CloudTextStorageIdentity(
      zoneName: "payload",
      ownerName: "owner",
      recordName: UUID().uuidString.lowercased()
    )
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.remoteMetadataAccepted(
        metadata: CloudAttachmentMetadataValue(
          attachmentID: deletedAttachmentID,
          snipID: replacement.metadata.snipID,
          position: replacement.metadata.position,
          fileName: "deleted.txt",
          contentType: "text/plain",
          byteCount: 7,
          sha256: Data(repeating: 7, count: 32),
          payloadIdentity: deletedPayloadIdentity
        ),
        metadataIdentity: deletedMetadataIdentity,
        shadowData: Data(),
        systemFields: Data()
      )]
    )
    let local = try await fixture.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: {
      $0.id == replacement.metadata.snipID
    }))
    _ = try await fixture.library.perform(
      .editAttachments(
        snipID: snip.id,
        content: snip.content,
        edits: [.existing(attachmentID: replacement.metadata.attachmentID)],
        expectedUpdatedAt: snip.updatedAt,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )
    _ = try await fixture.store.pendingChanges()
    let reconciled = try await snapshot(fixture.library, fixture.namespace)
    let currentReplacement = try XCTUnwrap(reconciled.publications.first(where: {
      $0.metadata.attachmentID == replacement.metadata.attachmentID
    }))
    let deleted = try XCTUnwrap(reconciled.publications.first(where: {
      $0.metadata.attachmentID == deletedAttachmentID
    }))
    XCTAssertFalse(deleted.isLocallyPresent)
    let remappedAttachmentID = UUID()
    let remappedMetadataIdentity = CloudTextStorageIdentity(
      zoneName: "data",
      ownerName: "owner",
      recordName: "a-\(remappedAttachmentID.uuidString.lowercased())"
    )

    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [
        .metadataUnknown(
          attachmentID: currentReplacement.metadata.attachmentID,
          expectedRevision: currentReplacement.revision,
          replacementAttachmentID: remappedAttachmentID,
          replacementMetadataIdentity: remappedMetadataIdentity
        ),
        .metadataDeleteAccepted(
          attachmentID: deleted.metadata.attachmentID,
          expectedRevision: deleted.revision
        ),
      ]
    )

    let after = try await snapshot(fixture.library, fixture.namespace)
    XCTAssertNotNil(after.publications.first(where: {
      $0.metadata.attachmentID == remappedAttachmentID
    }))
    XCTAssertEqual(after.cleanups.first(where: {
      $0.identity == deletedPayloadIdentity
    })?.blockedByAttachmentID, remappedAttachmentID)
  }

  // DC3, across batches: the stored cleanup was blocked by the replacement in an earlier batch,
  // so the later remap must move that stored blocker too.
  func testMetadataIdentityRemapInALaterBatchMovesTheStoredCleanupBlocker() async throws {
    let setup = try await makeRemovedPublishedAttachmentFixture()
    let fixture = setup.fixture
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let removed = setup.removed
    let remaining = setup.remaining
    let cleanupRecordID = CloudAttachmentRecordCodec.recordID(removed.metadata.payloadIdentity)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [
        .metadataDeleteAccepted(
          attachmentID: removed.metadata.attachmentID,
          expectedRevision: removed.revision
        ),
        .operationFailed(
          attachmentID: remaining.metadata.attachmentID,
          expectedRevision: remaining.revision,
          failure: .retryable
        ),
      ]
    )
    let blocked = try await snapshot(fixture.library, fixture.namespace)
    XCTAssertEqual(blocked.cleanups.first(where: {
      $0.identity == removed.metadata.payloadIdentity
    })?.blockedByAttachmentID, remaining.metadata.attachmentID)
    let retryBatch = try await fixture.store.pendingChanges()
    XCTAssertTrue(retryBatch.operations.contains(where: {
      $0.id == CloudAttachmentRecordCodec.recordID(remaining.metadataIdentity)
    }))
    XCTAssertFalse(retryBatch.operations.contains(where: { $0.id == cleanupRecordID }))
    let retrying = try await snapshot(fixture.library, fixture.namespace)
    let retryingReplacement = try XCTUnwrap(retrying.publications.first(where: {
      $0.metadata.attachmentID == remaining.metadata.attachmentID
    }))
    let remappedAttachmentID = UUID()
    let remappedMetadataIdentity = CloudTextStorageIdentity(
      zoneName: "data",
      ownerName: "owner",
      recordName: "a-\(remappedAttachmentID.uuidString.lowercased())"
    )

    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.metadataUnknown(
        attachmentID: remaining.metadata.attachmentID,
        expectedRevision: retryingReplacement.revision,
        replacementAttachmentID: remappedAttachmentID,
        replacementMetadataIdentity: remappedMetadataIdentity
      )]
    )

    try await assertCleanupWaitsForRemappedReplacement(
      fixture,
      removedPayload: removed.metadata.payloadIdentity,
      remainingOldPayload: remaining.metadata.payloadIdentity,
      replacedAttachmentID: remaining.metadata.attachmentID,
      remappedAttachmentID: remappedAttachmentID,
      remappedMetadataIdentity: remappedMetadataIdentity
    )
  }

  // DC3, one batch: results run in record-name order, so the delete can precede the remap and
  // insert a cleanup that still names the replacement's old ID.
  func testMetadataIdentityRemapAfterTheDeleteInOneBatchMovesTheNewCleanupBlocker() async throws {
    let setup = try await makeRemovedPublishedAttachmentFixture()
    let fixture = setup.fixture
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let removed = setup.removed
    let remaining = setup.remaining
    let remappedAttachmentID = UUID()
    let remappedMetadataIdentity = CloudTextStorageIdentity(
      zoneName: "data",
      ownerName: "owner",
      recordName: "a-\(remappedAttachmentID.uuidString.lowercased())"
    )

    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [
        .metadataDeleteAccepted(
          attachmentID: removed.metadata.attachmentID,
          expectedRevision: removed.revision
        ),
        .metadataUnknown(
          attachmentID: remaining.metadata.attachmentID,
          expectedRevision: remaining.revision,
          replacementAttachmentID: remappedAttachmentID,
          replacementMetadataIdentity: remappedMetadataIdentity
        ),
      ]
    )

    try await assertCleanupWaitsForRemappedReplacement(
      fixture,
      removedPayload: removed.metadata.payloadIdentity,
      remainingOldPayload: remaining.metadata.payloadIdentity,
      replacedAttachmentID: remaining.metadata.attachmentID,
      remappedAttachmentID: remappedAttachmentID,
      remappedMetadataIdentity: remappedMetadataIdentity
    )
  }

  func testRemovingAndRestoringADownloadedAttachmentKeepsItsPublishedMetadata() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "downloaded attachment",
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
    let namespace = namespaceValue()
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: CloudZoneID(name: "data", ownerName: "owner"),
      payloadZone: CloudZoneID(name: "payload", ownerName: "owner")
    )
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
    let bytes = Data("downloaded, removed, and restored".utf8)
    let shadow = try metadataShadow(metadataIdentity)
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace.namespaceKey,
      transitions: [.remoteMetadataAccepted(
        metadata: CloudAttachmentMetadataValue(
          attachmentID: attachmentID,
          snipID: snipID,
          position: 0,
          fileName: "downloaded.txt",
          contentType: "text/plain",
          byteCount: Int64(bytes.count),
          sha256: Data(SHA256.hash(data: bytes)),
          payloadIdentity: payloadIdentity
        ),
        metadataIdentity: metadataIdentity,
        shadowData: shadow.data,
        systemFields: shadow.systemFields
      )]
    )
    let stagingRoot = try await library.cloudAttachmentStagingRoot(
      namespaceKey: namespace.namespaceKey
    )
    let staged = stagingRoot.appendingPathComponent("restore/payload")
    try FileManager.default.createDirectory(
      at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try bytes.write(to: staged)
    _ = try await library.installCloudAttachmentDownload(
      namespaceKey: namespace.namespaceKey,
      attachmentID: attachmentID,
      expectedPayloadIdentity: payloadIdentity,
      expectedField: CloudAttachmentRecordCodec.assetField,
      download: CloudAttachmentCacheDownload(
        payloadIdentity: payloadIdentity,
        field: CloudAttachmentRecordCodec.assetField,
        fileURL: staged,
        byteCount: Int64(bytes.count),
        sha256: Data(SHA256.hash(data: bytes))
      ),
      maximumBytes: 1_024,
      now: .distantPast
    )
    let metadataRecordID = CloudAttachmentRecordCodec.recordID(metadataIdentity)
    let publishedStorage = try await snapshot(library, namespace)
    let published = try XCTUnwrap(publishedStorage.publications.first)
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == snipID }))
    XCTAssertEqual(snip.attachments.map(\.id), [attachmentID])
    XCTAssertTrue(snip.attachments.first?.relativePath.hasPrefix("CloudDownloads/") == true)

    _ = try await library.perform(.delete(ids: [snipID]), sortedBy: .manual)
    let removalBatch = try await store.pendingChanges()

    let removedStorage = try await snapshot(library, namespace)
    let removed = try XCTUnwrap(removedStorage.publications.first)
    XCTAssertFalse(removed.isLocallyPresent)
    XCTAssertTrue(removed.metadataAccepted)
    XCTAssertNil(removed.lastFailure)
    XCTAssertEqual(removed.revision, published.revision + 1)
    let plansMetadataDelete = removalBatch.operations.contains(where: { operation in
      guard case .delete(let id, _) = operation else { return false }
      return id == metadataRecordID
    })
    XCTAssertTrue(plansMetadataDelete)

    _ = try await library.perform(.restore(snips: [snip]), sortedBy: .manual)
    let restoreBatch = try await store.pendingChanges()

    let restoredStorage = try await snapshot(library, namespace)
    let restored = try XCTUnwrap(restoredStorage.publications.first)
    XCTAssertTrue(restored.isLocallyPresent)
    XCTAssertTrue(restored.payloadAccepted)
    XCTAssertTrue(restored.metadataAccepted)
    XCTAssertNil(restored.lastFailure)
    XCTAssertFalse(restoreBatch.operations.contains(where: { $0.id == metadataRecordID }))
    let restoredLocal = try await library.checkedSnapshot(sortedBy: .manual)
    let restoredURL = try XCTUnwrap(restoredLocal.attachmentURLs[attachmentID])
    XCTAssertEqual(try Data(contentsOf: restoredURL), bytes)
  }

  func testPendingMetadataDoesNotDelayUnrelatedPayloadCleanup() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first.txt")
    let second = root.appendingPathComponent("second.txt")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "cleanup fairness",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [first, second],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(
      server: server,
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    try await store.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let sync = CloudFullSyncCoordinator(
      store: store,
      transport: transport,
      fetchScope: .zones([dataZone])
    )
    try await sync.sync()
    try await sync.sync()
    let accepted = try await snapshot(library, namespace)
    let ordered = accepted.publications.sorted { $0.metadata.fileName < $1.metadata.fileName }
    let replacing = try XCTUnwrap(ordered.first)
    let removing = try XCTUnwrap(ordered.last)
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == snipID }))
    _ = try await library.perform(
      .editAttachments(
        snipID: snipID,
        content: snip.content,
        edits: [.existing(attachmentID: replacing.metadata.attachmentID)],
        expectedUpdatedAt: snip.updatedAt,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )
    try await sync.sendPending()
    let withCleanup = try await snapshot(library, namespace)
    let cleanup = try XCTUnwrap(withCleanup.cleanups.first(where: {
      $0.identity == removing.metadata.payloadIdentity
    }))
    let replacement = root.appendingPathComponent("replacement.txt")
    try Data("replacement".utf8).write(to: replacement)
    let updated = try await library.checkedSnapshot(sortedBy: .manual)
    let updatedSnip = try XCTUnwrap(updated.snips.first(where: { $0.id == snipID }))
    _ = try await library.perform(
      .editAttachments(
        snipID: snipID,
        content: updatedSnip.content,
        edits: [.replacement(
          attachmentID: replacing.metadata.attachmentID,
          sourceURL: replacement
        )],
        expectedUpdatedAt: updatedSnip.updatedAt,
        now: Date(timeIntervalSince1970: 3)
      ),
      sortedBy: .manual
    )
    _ = try await store.pendingChanges()
    let prepared = try await snapshot(library, namespace)
    let replacementPublication = try XCTUnwrap(prepared.publications.first(where: {
      $0.metadata.fileName == "replacement.txt"
    }))
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace.namespaceKey,
      transitions: [.payloadAccepted(
        attachmentID: replacementPublication.metadata.attachmentID,
        expectedRevision: replacementPublication.revision,
        shadowData: Data("payload-shadow".utf8),
        systemFields: Data()
      )]
    )

    let pending = try await store.pendingChanges()
    let pendingIDs = Set(pending.operations.map(\.id))

    XCTAssertTrue(pendingIDs.contains(CloudAttachmentRecordCodec.recordID(
      replacementPublication.metadataIdentity
    )))
    XCTAssertTrue(pendingIDs.contains(CloudAttachmentRecordCodec.recordID(cleanup.identity)))
  }

  func testTerminalMetadataDeleteAndCleanupFailuresDoNotRetryOrStarveOtherCleanup() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = ["first", "second", "third"].map { name in
      root.appendingPathComponent("\(name).txt")
    }
    for (index, source) in sources.enumerated() {
      try Data("payload-\(index)".utf8).write(to: source)
    }
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "delete fairness",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: sources,
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(
      server: server,
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    try await store.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let sync = CloudFullSyncCoordinator(
      store: store,
      transport: transport,
      fetchScope: .zones([dataZone])
    )
    try await sync.sync()
    try await sync.sync()
    let accepted = try await snapshot(library, namespace)
    let ordered = accepted.publications.sorted { $0.metadata.fileName < $1.metadata.fileName }
    let failedDelete = try XCTUnwrap(ordered.first)
    let failedDeleteID = CloudAttachmentRecordCodec.recordID(failedDelete.metadataIdentity)
    await transport.failNextSentItem(failedDeleteID, failure: .rejected)
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == snipID }))
    _ = try await library.perform(
      .editAttachments(
        snipID: snipID,
        content: snip.content,
        edits: [],
        expectedUpdatedAt: snip.updatedAt,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )

    try await sync.sendPending()

    let afterDeletes = try await snapshot(library, namespace)
    XCTAssertEqual(afterDeletes.publications.first?.lastFailure, .rejected)
    XCTAssertEqual(afterDeletes.cleanups.count, 2)
    let failedCleanup = try XCTUnwrap(afterDeletes.cleanups.first)
    let successfulCleanup = try XCTUnwrap(afterDeletes.cleanups.last)
    let failedCleanupID = CloudAttachmentRecordCodec.recordID(failedCleanup.identity)
    let successfulCleanupID = CloudAttachmentRecordCodec.recordID(successfulCleanup.identity)
    await transport.failNextSentItem(failedCleanupID, failure: .rejected)

    try await sync.sendPending()
    try await sync.sendPending()

    let failedPayload = await server.fullSnapshot(for: failedCleanupID)
    let cleanedPayload = await server.fullSnapshot(for: successfulCleanupID)
    XCTAssertNotNil(failedPayload)
    XCTAssertNil(cleanedPayload)
    let sentIDs = await transport.events().compactMap { event -> [CloudRecordID]? in
      guard case .sent(let ids) = event else { return nil }
      return ids
    }.flatMap { $0 }
    XCTAssertEqual(sentIDs.filter { $0 == failedDeleteID }.count, 2)
    XCTAssertEqual(sentIDs.filter { $0 == failedCleanupID }.count, 2)
  }

  func testNewNamespaceCannotSendOldQueuedWorkAndOldOfflineBytesSurvive() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("offline.txt")
    let bytes = Data("not uploaded yet".utf8)
    try bytes.write(to: source)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    _ = try await library.perform(
      .add(
        content: "offline",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    let oldNamespace = namespaceValue()
    let oldStore = CloudFullSyncPersistence(
      library: library,
      namespace: oldNamespace,
      dataZone: CloudZoneID(name: "data", ownerName: "owner"),
      payloadZone: CloudZoneID(name: "payload", ownerName: "owner")
    )
    _ = try await oldStore.pendingChanges()
    let oldStorage = try await snapshot(library, oldNamespace)
    let oldPublication = try XCTUnwrap(oldStorage.publications.first)
    let oldUpload = try XCTUnwrap(oldPublication.sourceURL)

    let newDataZone = CloudZoneID(name: "next-data", ownerName: "owner")
    let newPayloadZone = CloudZoneID(name: "next-payload", ownerName: "owner")
    let newNamespace = CloudSyncNamespace(
      cloudScope: "private",
      accountLineage: "next-account",
      generation: UUID(),
      zones: [newDataZone, newPayloadZone]
    )
    let newStore = CloudFullSyncPersistence(
      library: library,
      namespace: newNamespace,
      dataZone: newDataZone,
      payloadZone: newPayloadZone
    )
    let newBatch = try await newStore.pendingChanges()
    let oldIDs = Set([
      CloudAttachmentRecordCodec.recordID(oldPublication.metadataIdentity),
      CloudAttachmentRecordCodec.recordID(oldPublication.metadata.payloadIdentity),
    ])
    XCTAssertTrue(Set(newBatch.operations.map(\.id)).isDisjoint(with: oldIDs))
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldUpload.path))
    XCTAssertEqual(try Data(contentsOf: oldUpload), bytes)
    let stillDormant = try await snapshot(library, oldNamespace)
    XCTAssertEqual(stillDormant.publications.first?.sourceURL, oldUpload)
  }

  func testDestructiveFetchBlocksQueuedAttachmentBeforeAnySameRunSend() async throws {
    for reason in [CloudZoneDeletionReason.purged, .encryptedDataReset] {
      let root = temporaryDirectory()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let namespace = namespaceValue()
      let dataZone = CloudZoneID(name: "data", ownerName: "owner")
      let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
      let source = root.appendingPathComponent("offline.txt")
      try Data("keep local".utf8).write(to: source)
      let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
      let added = try await library.perform(
        .add(
          content: "not uploaded after reset",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inbox.id,
          attachmentURLs: [source],
          requestID: UUID(),
          now: .distantPast
        ),
        sortedBy: .manual
      )
      guard case .add(.added(let snipID)) = added.outcome else {
        return XCTFail("Expected a saved snip")
      }
      let server = FakeCloudServer()
      await server.emitZoneDeletion(dataZone, reason: reason)
      let transport = FakeCloudRecordTransport(
        server: server,
        namespace: namespace,
        automaticallyFetchedZones: [dataZone]
      )
      let store = CloudFullSyncPersistence(
        library: library,
        namespace: namespace,
        dataZone: dataZone,
        payloadZone: payloadZone
      )
      try await store.approveEnrollment(references: [
        CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
        CloudEntityReference(kind: .snip, domainID: snipID),
      ])
      let sync = CloudFullSyncCoordinator(
        store: store,
        transport: transport,
        fetchScope: .zones([dataZone])
      )

      try await sync.sync()

      let sent = await transport.events().compactMap { event -> [CloudRecordID]? in
        guard case .sent(let ids) = event else { return nil }
        return ids
      }.flatMap { $0 }
      XCTAssertTrue(sent.isEmpty)
      XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(added.snapshot.attachmentURLs.values.first)), Data("keep local".utf8))
      let pending = try await store.pendingChanges()
      XCTAssertTrue(pending.operations.isEmpty)
    }
  }

  func testDeleteConflictsRetryFromServerShadowsThroughPayloadCleanup() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let source = root.appendingPathComponent("delete.txt")
    try Data("delete me".utf8).write(to: source)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "delete conflict",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let server = FakeCloudServer()
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    try await store.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let sync = CloudFullSyncCoordinator(
      store: store,
      transport: FakeCloudRecordTransport(
        server: server,
        namespace: namespace,
        automaticallyFetchedZones: [dataZone]
      ),
      fetchScope: .zones([dataZone])
    )
    try await sync.sync()
    try await sync.sync()
    let settled = try await snapshot(library, namespace)
    let publication = try XCTUnwrap(settled.publications.first)
    let metadataID = CloudAttachmentRecordCodec.recordID(publication.metadataIdentity)
    let payloadID = CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity)

    let fetchedServerMetadata = await server.fullSnapshot(for: metadataID)
    let serverMetadata = try XCTUnwrap(fetchedServerMetadata)
    var externalMetadataFields = serverMetadata.encryptedFields
    externalMetadataFields["futureDeleteField"] = .string("preserve")
    _ = try await server.send(
      CloudOutboundBatch(operations: [.save(CloudRecordDraft(
        id: metadataID,
        recordType: serverMetadata.recordType,
        schemaVersion: serverMetadata.schemaVersion,
        routingFields: serverMetadata.routingFields,
        encryptedFields: externalMetadataFields,
        base: serverMetadata.shadow
      ))]),
      failures: [:]
    )
    let currentSnapshot = try await library.checkedSnapshot(sortedBy: .manual)
    let current = try XCTUnwrap(currentSnapshot.snips.first)
    _ = try await library.perform(
      .editAttachments(
        snipID: snipID,
        content: current.content,
        edits: [],
        expectedUpdatedAt: current.updatedAt,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )

    try await sync.sendPending()
    let metadataAfterConflict = await server.fullSnapshot(for: metadataID)
    XCTAssertNotNil(metadataAfterConflict)
    try await sync.sendPending()
    let metadataAfterRetry = await server.fullSnapshot(for: metadataID)
    XCTAssertNil(metadataAfterRetry)

    let fetchedServerPayload = await server.fullSnapshot(for: payloadID)
    let serverPayload = try XCTUnwrap(fetchedServerPayload)
    var externalPayloadFields = serverPayload.encryptedFields
    externalPayloadFields["futureDeleteField"] = .string("preserve")
    _ = try await server.send(
      CloudOutboundBatch(operations: [.save(CloudRecordDraft(
        id: payloadID,
        recordType: serverPayload.recordType,
        schemaVersion: serverPayload.schemaVersion,
        routingFields: serverPayload.routingFields,
        encryptedFields: externalPayloadFields,
        base: serverPayload.shadow
      ))]),
      failures: [:]
    )
    try await sync.sendPending()
    let payloadAfterConflict = await server.fullSnapshot(for: payloadID)
    XCTAssertNotNil(payloadAfterConflict)
    try await sync.sendPending()
    let payloadAfterRetry = await server.fullSnapshot(for: payloadID)
    XCTAssertNil(payloadAfterRetry)
    let final = try await snapshot(library, namespace)
    XCTAssertTrue(final.cleanups.isEmpty)
  }

  func testNormalFullSyncFetchExcludesPayloadZone() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let namespace = CloudSyncNamespace(
      cloudScope: "private",
      accountLineage: "account",
      generation: UUID(),
      zones: [dataZone, payloadZone]
    )
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    let transport = FakeCloudRecordTransport(
      server: FakeCloudServer(),
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    let coordinator = CloudFullSyncCoordinator(
      store: persistence,
      transport: transport,
      fetchScope: .zones([dataZone])
    )

    try await coordinator.fetchRemote()

    let scopes = await transport.fetchScopes()
    XCTAssertEqual(scopes, [.zones([dataZone])])
  }

  func testRemoteMetadataAcceptanceIsDurableAndHistoryReplaySafeWithoutFetchingPayload() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let namespace = CloudSyncNamespace(
      cloudScope: "private",
      accountLineage: "account",
      generation: UUID(),
      zones: [dataZone, payloadZone]
    )
    let attachmentID = UUID()
    let publication = CloudAttachmentPublication(
      metadata: CloudAttachmentMetadataValue(
        attachmentID: attachmentID,
        snipID: UUID(),
        position: 0,
        fileName: "remote.pdf",
        contentType: "application/pdf",
        byteCount: 42,
        sha256: Data(repeating: 7, count: 32),
        payloadIdentity: CloudTextStorageIdentity(
          zoneName: payloadZone.name,
          ownerName: payloadZone.ownerName,
          recordName: UUID().uuidString.lowercased()
        )
      ),
      metadataIdentity: CloudTextStorageIdentity(
        zoneName: dataZone.name,
        ownerName: dataZone.ownerName,
        recordName: "a-\(attachmentID.uuidString.lowercased())"
      ),
      sourceURL: nil,
      payloadAccepted: true,
      payloadShadowData: nil,
      metadataAccepted: false,
      metadataShadowData: nil,
      revision: 1
    )
    let server = FakeCloudServer()
    let writer = FakeCloudRecordTransport(server: server)
    let sent = try await writer.send(CloudOutboundBatch(
      operations: [.save(try CloudAttachmentRecordCodec.metadataDraft(publication))]
    ))
    try await writer.confirmApplied(sent.id)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    let reader = FakeCloudRecordTransport(
      server: server,
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    let coordinator = CloudFullSyncCoordinator(
      store: persistence,
      transport: reader,
      fetchScope: .zones([dataZone])
    )

    try await coordinator.fetchRemote()
    try await coordinator.fetchRemote()

    let accepted = try await snapshot(library, namespace)
    XCTAssertEqual(accepted.publications.count, 1)
    XCTAssertEqual(accepted.publications.first?.metadata, publication.metadata)
    XCTAssertTrue(accepted.publications.first?.metadataAccepted == true)
    XCTAssertNil(accepted.publications.first?.sourceURL)
    let payloadSaveCount = await server.acceptedOperationCount(
      for: CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity)
    )
    XCTAssertEqual(payloadSaveCount, 0)
  }

  func testTwentyFiveMiBDownloadVerifiesHashRetriesInterruptionAndUsesBoundedCache() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("payload.txt")
    let bytes = Data(
      repeating: 0xA5,
      count: Int(SnipSnapCloudAttachmentLimits.maximumFileBytes)
    )
    let expectedSHA256 = Data(SHA256.hash(data: bytes))
    try bytes.write(to: source)
    let storeURL = root.appendingPathComponent("store")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
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
    try await library.reconcileCloudAttachments(
      namespaceKey: namespace.namespaceKey,
      metadataZoneName: dataZone.name,
      metadataOwnerName: dataZone.ownerName,
      payloadZoneName: payloadZone.name,
      payloadOwnerName: payloadZone.ownerName
    )
    let initialSnapshot = try await snapshot(library, namespace)
    let initial = try XCTUnwrap(initialSnapshot.publications.first)
    XCTAssertEqual(initial.metadata.byteCount, SnipSnapCloudAttachmentLimits.maximumFileBytes)
    XCTAssertEqual(initial.metadata.sha256, expectedSHA256)
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
    let payloadResult = try await transport.send(CloudOutboundBatch(
      operations: [.save(try CloudAttachmentRecordCodec.payloadDraft(initial))],
      zonesToSave: [payloadZone]
    ))
    guard case .saved(let payloadSnapshot) = try XCTUnwrap(payloadResult.items.first) else {
      return XCTFail("Expected payload save")
    }
    try await transport.confirmApplied(payloadResult.id)
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace.namespaceKey,
      transitions: [.payloadAccepted(
        attachmentID: initial.metadata.attachmentID,
        expectedRevision: initial.revision,
        shadowData: payloadSnapshot.shadow.data,
        systemFields: payloadSnapshot.shadow.systemFields
      )]
    )
    let acceptedSnapshot = try await snapshot(library, namespace)
    let payloadAccepted = try XCTUnwrap(acceptedSnapshot.publications.first)
    let metadataResult = try await transport.send(CloudOutboundBatch(
      operations: [.save(try CloudAttachmentRecordCodec.metadataDraft(payloadAccepted))],
      zonesToSave: [dataZone]
    ))
    guard case .saved(let metadataSnapshot) = try XCTUnwrap(metadataResult.items.first) else {
      return XCTFail("Expected metadata save")
    }
    try await transport.confirmApplied(metadataResult.id)
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace.namespaceKey,
      transitions: [.metadataAccepted(
        attachmentID: initial.metadata.attachmentID,
        expectedRevision: payloadAccepted.revision,
        shadowData: metadataSnapshot.shadow.data,
        systemFields: metadataSnapshot.shadow.systemFields
      )]
    )

    let receiverLibrary = try SwiftDataSnipLibrary(
      storeURL: root.appendingPathComponent("receiver.store")
    )
    let receiverStore = CloudFullSyncPersistence(
      library: receiverLibrary,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    let receiver = CloudFullSyncCoordinator(
      store: receiverStore,
      transport: FakeCloudRecordTransport(
        server: server,
        namespace: namespace,
        automaticallyFetchedZones: [dataZone]
      ),
      fetchScope: .zones([dataZone])
    )
    try await receiver.fetchRemote()
    let downloads = CloudAttachmentTransferCoordinator(
      library: receiverLibrary,
      namespace: namespace,
      payloadZone: payloadZone,
      transport: transport,
      maximumCacheBytes: SnipSnapCloudAttachmentLimits.maximumFileBytes,
      now: { Date(timeIntervalSince1970: 10) }
    )
    let invalidReceiptDownloads = CloudAttachmentTransferCoordinator(
      library: receiverLibrary,
      namespace: namespace,
      payloadZone: payloadZone,
      transport: MismatchedAssetReceiptTransport(base: transport),
      maximumCacheBytes: SnipSnapCloudAttachmentLimits.maximumFileBytes
    )
    do {
      _ = try await invalidReceiptDownloads.download(
        attachmentID: initial.metadata.attachmentID
      )
      XCTFail("A mismatched asset receipt must not be installed.")
    } catch {
      XCTAssertEqual(error as? CloudAttachmentStorageError, .invalidMetadata)
    }
    let invalidReceiptStagingRoot = try await receiverLibrary.cloudAttachmentStagingRoot(
      namespaceKey: namespace.namespaceKey
    )
    let stagedFiles = FileManager.default.enumerator(
      at: invalidReceiptStagingRoot,
      includingPropertiesForKeys: [.isRegularFileKey]
    )?.compactMap { item -> URL? in
      guard let url = item as? URL,
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      else { return nil }
      return url
    } ?? []
    XCTAssertTrue(stagedFiles.isEmpty)
    let outsideReceiptFile = root.appendingPathComponent("outside-receipt.txt")
    try bytes.write(to: outsideReceiptFile)
    let outsideReceiptDownloads = CloudAttachmentTransferCoordinator(
      library: receiverLibrary,
      namespace: namespace,
      payloadZone: payloadZone,
      transport: OutsideAssetReceiptTransport(fileURL: outsideReceiptFile),
      maximumCacheBytes: SnipSnapCloudAttachmentLimits.maximumFileBytes
    )
    do {
      _ = try await outsideReceiptDownloads.download(
        attachmentID: initial.metadata.attachmentID
      )
      XCTFail("A receipt outside staging must not be installed.")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: outsideReceiptFile), bytes)
    enum InjectedLocalStorageFailure: Error { case full }
    let failingLibrary = try SwiftDataSnipLibrary(
      storeURL: root.appendingPathComponent("receiver.store"),
      afterMutationBeforeSave: { throw InjectedLocalStorageFailure.full }
    )
    let failingDownloads = CloudAttachmentTransferCoordinator(
      library: failingLibrary,
      namespace: namespace,
      payloadZone: payloadZone,
      transport: transport,
      maximumCacheBytes: SnipSnapCloudAttachmentLimits.maximumFileBytes
    )
    do {
      _ = try await failingDownloads.download(attachmentID: initial.metadata.attachmentID)
      XCTFail("A local storage failure must not publish an untracked cache file.")
    } catch is InjectedLocalStorageFailure {}
    let afterLocalFailure = try await snapshot(receiverLibrary, namespace)
    XCTAssertTrue(afterLocalFailure.cacheEntries.isEmpty)
    XCTAssertTrue(afterLocalFailure.publications.first?.metadataAccepted == true)
    await transport.failNextAssetFetch()
    do {
      _ = try await downloads.download(attachmentID: initial.metadata.attachmentID)
      XCTFail("An interrupted direct fetch should fail without hiding the remote metadata.")
    } catch {
      XCTAssertEqual(error as? FakeCloudError, .injectedAssetFailure)
    }
    let afterInterruption = try await snapshot(receiverLibrary, namespace)
    XCTAssertEqual(afterInterruption.publications.count, 1)
    XCTAssertTrue(afterInterruption.cacheEntries.isEmpty)
    let downloaded = try await downloads.download(attachmentID: initial.metadata.attachmentID)
    XCTAssertEqual(try Data(contentsOf: downloaded), bytes)
    let filesRoot = downloaded.deletingLastPathComponent().deletingLastPathComponent()
    let orphan = filesRoot.appendingPathComponent("orphan/file", isDirectory: false)
    try FileManager.default.createDirectory(
      at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("orphan".utf8).write(to: orphan)
    let stagingRoot = try await receiverLibrary.cloudAttachmentStagingRoot(
      namespaceKey: namespace.namespaceKey
    )
    let interrupted = stagingRoot.appendingPathComponent("interrupted/payload")
    try FileManager.default.createDirectory(
      at: interrupted.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("partial".utf8).write(to: interrupted)
    let reopenedDownloads = CloudAttachmentTransferCoordinator(
      library: receiverLibrary,
      namespace: namespace,
      payloadZone: payloadZone,
      transport: transport,
      maximumCacheBytes: SnipSnapCloudAttachmentLimits.maximumFileBytes,
      now: { Date(timeIntervalSince1970: 11) }
    )
    _ = try await reopenedDownloads.downloadedURL(attachmentID: initial.metadata.attachmentID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
    for use in [
      SyncedAttachmentUse.preview,
      .open,
      .copy,
      .export,
    ] {
      let prepared = try await downloads.prepare(
        attachmentID: initial.metadata.attachmentID,
        for: use
      )
      XCTAssertEqual(prepared, downloaded)
    }
    let cached = try await downloads.downloadedURL(attachmentID: initial.metadata.attachmentID)
    XCTAssertEqual(cached, downloaded)
    let outsideCache = root.appendingPathComponent("outside-cache.txt")
    try bytes.write(to: outsideCache)
    try FileManager.default.removeItem(at: downloaded)
    try FileManager.default.createSymbolicLink(at: downloaded, withDestinationURL: outsideCache)
    let rejectedSymlink = try await downloads.downloadedURL(
      attachmentID: initial.metadata.attachmentID
    )
    XCTAssertNil(rejectedSymlink)
    XCTAssertEqual(try Data(contentsOf: outsideCache), bytes)
    let redownloaded = try await downloads.download(attachmentID: initial.metadata.attachmentID)
    let replacementBytes = Data("replacement from another client".utf8)
    let replacementSource = root.appendingPathComponent("remote-replacement.txt")
    try replacementBytes.write(to: replacementSource)
    let replacementPayloadIdentity = CloudTextStorageIdentity(
      zoneName: payloadZone.name,
      ownerName: payloadZone.ownerName,
      recordName: UUID().uuidString.lowercased()
    )
    let replacementMetadata = CloudAttachmentMetadataValue(
      attachmentID: initial.metadata.attachmentID,
      snipID: initial.metadata.snipID,
      position: initial.metadata.position,
      fileName: "remote-replacement.txt",
      contentType: "text/plain",
      byteCount: Int64(replacementBytes.count),
      sha256: Data(SHA256.hash(data: replacementBytes)),
      payloadIdentity: replacementPayloadIdentity
    )
    let replacementPublication = CloudAttachmentPublication(
      metadata: replacementMetadata,
      metadataIdentity: initial.metadataIdentity,
      sourceURL: replacementSource,
      payloadAccepted: false,
      payloadShadowData: nil,
      metadataAccepted: true,
      metadataShadowData: metadataSnapshot.shadow.data,
      revision: 0
    )
    let otherClient = FakeCloudRecordTransport(server: server, namespace: namespace)
    let replacementPayloadResult = try await otherClient.send(CloudOutboundBatch(
      operations: [.save(try CloudAttachmentRecordCodec.payloadDraft(replacementPublication))]
    ))
    try await otherClient.confirmApplied(replacementPayloadResult.id)
    let replacementMetadataResult = try await otherClient.send(CloudOutboundBatch(
      operations: [.save(try CloudAttachmentRecordCodec.metadataDraft(replacementPublication))]
    ))
    try await otherClient.confirmApplied(replacementMetadataResult.id)
    try await receiver.fetchRemote()
    XCTAssertFalse(FileManager.default.fileExists(atPath: redownloaded.path))
    let invalidatedDownload = try await downloads.downloadedURL(
      attachmentID: initial.metadata.attachmentID
    )
    XCTAssertNil(invalidatedDownload)
    let replacementDownload = try await downloads.download(
      attachmentID: initial.metadata.attachmentID
    )
    XCTAssertEqual(try Data(contentsOf: replacementDownload), replacementBytes)
    try FileManager.default.createDirectory(
      at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("orphan again".utf8).write(to: orphan)
    try await downloads.clearDownloads()
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    let cleared = try await downloads.downloadedURL(attachmentID: initial.metadata.attachmentID)
    XCTAssertNil(cleared)
    let afterClear = try await snapshot(receiverLibrary, namespace)
    XCTAssertEqual(afterClear.publications.count, 1)
    XCTAssertTrue(afterClear.publications[0].metadataAccepted)
  }

  func testCompatibilityListsEveryUnsupportedAttachment() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first.bin")
    let second = root.appendingPathComponent("second.bin")
    try Data(repeating: 1, count: 5).write(to: first)
    try Data(repeating: 2, count: 6).write(to: second)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let namespace = namespaceValue()
    _ = try await library.perform(
      .add(
        content: "two files",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [first, second],
        requestID: UUID(),
        now: .distantPast
      ), sortedBy: .manual
    )
    try await library.reconcileCloudAttachments(
      namespaceKey: namespace.namespaceKey,
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let coordinator = CloudAttachmentTransferCoordinator(
      library: library,
      namespace: namespace,
      payloadZone: CloudZoneID(name: "payload", ownerName: "owner"),
      transport: FakeCloudRecordTransport(server: FakeCloudServer()),
      maximumCacheBytes: 1024
    )
    let unsupported = try await coordinator.unsupportedFiles(
      policy: CloudAttachmentCompatibilityPolicy(
        maximumFileBytes: 10,
        maximumAttachmentBytesPerSnip: 10
      )
    )
    XCTAssertEqual(unsupported.map(\.fileName), ["first.bin", "second.bin"])
    XCTAssertEqual(
      unsupported.map(\.reason),
      Array(repeating: .snipTotalTooLarge(maximumBytes: 10), count: 2)
    )
  }

  func testAcceptedRemoteOnlyAttachmentCountsTowardSnipTotalWithoutMissingFileError() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let localURL = root.appendingPathComponent("local.bin")
    try Data(repeating: 1, count: 30).write(to: localURL)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "local and remote",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [localURL],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let namespace = namespaceValue()
    try await library.reconcileCloudAttachments(
      namespaceKey: namespace.namespaceKey,
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let remoteID = UUID()
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace.namespaceKey,
      transitions: [
        .remoteMetadataAccepted(
          metadata: CloudAttachmentMetadataValue(
            attachmentID: remoteID,
            snipID: snipID,
            position: 1,
            fileName: "remote.bin",
            contentType: "application/octet-stream",
            byteCount: 80,
            sha256: Data(repeating: 2, count: 32),
            payloadIdentity: CloudTextStorageIdentity(
              zoneName: "payload",
              ownerName: "owner",
              recordName: remoteID.uuidString
            )
          ),
          metadataIdentity: CloudTextStorageIdentity(
            zoneName: "data",
            ownerName: "owner",
            recordName: remoteID.uuidString
          ),
          shadowData: Data("shadow".utf8),
          systemFields: Data("fields".utf8)
        )
      ]
    )
    let coordinator = CloudAttachmentTransferCoordinator(
      library: library,
      namespace: namespace,
      payloadZone: CloudZoneID(name: "payload", ownerName: "owner"),
      transport: FakeCloudRecordTransport(server: FakeCloudServer()),
      maximumCacheBytes: 1024
    )
    let unsupported = try await coordinator.unsupportedFiles(
      policy: CloudAttachmentCompatibilityPolicy(
        maximumAttachmentBytesPerSnip: 100
      )
    )

    XCTAssertEqual(unsupported.map(\.fileName), ["local.bin"])
    XCTAssertEqual(unsupported.first?.reason, .snipTotalTooLarge(maximumBytes: 100))
  }

  func testActiveSyncQuarantinesOversizeAttachmentsWithoutBlockingOtherRecords() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first.bin")
    let second = root.appendingPathComponent("second.bin")
    try Data(repeating: 1, count: 5).write(to: first)
    try Data(repeating: 2, count: 6).write(to: second)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "too large after sync is on",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [first, second],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let server = FakeCloudServer()
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone,
      attachmentPolicy: CloudAttachmentCompatibilityPolicy(
        maximumFileBytes: 10,
        maximumAttachmentBytesPerSnip: 10
      )
    )
    try await store.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let sync = CloudFullSyncCoordinator(
      store: store,
      transport: FakeCloudRecordTransport(
        server: server,
        namespace: namespace,
        automaticallyFetchedZones: [dataZone]
      ),
      fetchScope: .zones([dataZone])
    )

    try await sync.sync()

    let storage = try await snapshot(library, namespace)
    XCTAssertEqual(storage.publications.count, 2)
    for publication in storage.publications {
      let payloadSendCount = await server.acceptedOperationCount(
        for: CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity)
      )
      let metadataSendCount = await server.acceptedOperationCount(
        for: CloudAttachmentRecordCodec.recordID(publication.metadataIdentity)
      )
      XCTAssertEqual(payloadSendCount, 0)
      XCTAssertEqual(metadataSendCount, 0)
      XCTAssertEqual(publication.lastFailure, .invalidRecord)
    }
    let snipSendCount = await server.acceptedOperationCount(
      for: .snip(snipID, in: dataZone)
    )
    XCTAssertEqual(snipSendCount, 1)
    XCTAssertEqual(added.snapshot.snips.first?.attachments.count, 2)
  }

  func testPublicCompatibilityPolicyUsesTheTestedSnipSnapLimits() {
    XCTAssertEqual(
      CloudAttachmentCompatibilityPolicy.openSourceDefault.maximumFileBytes,
      25 * 1_048_576
    )
    XCTAssertEqual(
      CloudAttachmentCompatibilityPolicy.openSourceDefault.maximumAttachmentBytesPerSnip,
      100 * 1_048_576
    )
  }

  func testLocalOnlyLibraryKeepsAttachmentAboveTheSyncLimit() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("local-only-large.bin")
    _ = FileManager.default.createFile(atPath: source.path, contents: nil)
    let handle = try FileHandle(forWritingTo: source)
    try handle.truncate(
      atOffset: UInt64(SnipSnapCloudAttachmentLimits.maximumFileBytes + 1)
    )
    try handle.close()
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("local.store"))

    let saved = try await library.perform(
      .add(
        content: "local-only large file",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )

    let attachment = try XCTUnwrap(saved.snapshot.snips.first?.attachments.first)
    let storedURL = try XCTUnwrap(saved.snapshot.attachmentURLs[attachment.id])
    XCTAssertEqual(
      attachment.byteCount,
      SnipSnapCloudAttachmentLimits.maximumFileBytes + 1
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))
  }

  func testCompatibilityLimitsAreInclusiveAndReportEveryFileInAnOversizeSnip() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let policy = CloudAttachmentCompatibilityPolicy(
      maximumFileBytes: 25,
      maximumAttachmentBytesPerSnip: 100
    )

    let atBoundary = try compatibilitySnapshot(
      in: root.appendingPathComponent("boundary"),
      sizes: [25, 25, 25, 25]
    )
    XCTAssertTrue(
      CloudAttachmentTransferCoordinator.unsupportedFiles(
        in: atBoundary,
        policy: policy
      ).isEmpty
    )

    let fileOverflow = try compatibilitySnapshot(
      in: root.appendingPathComponent("file-overflow"),
      sizes: [26, 27]
    )
    let oversizedFiles = CloudAttachmentTransferCoordinator.unsupportedFiles(
      in: fileOverflow,
      policy: policy
    )
    XCTAssertEqual(oversizedFiles.map(\.fileName), ["file-0.bin", "file-1.bin"])
    XCTAssertEqual(
      oversizedFiles.map(\.reason),
      [.fileTooLarge(maximumBytes: 25), .fileTooLarge(maximumBytes: 25)]
    )

    let totalOverflow = try compatibilitySnapshot(
      in: root.appendingPathComponent("total-overflow"),
      sizes: [25, 25, 25, 25, 1]
    )
    let oversizedSnip = CloudAttachmentTransferCoordinator.unsupportedFiles(
      in: totalOverflow,
      policy: policy
    )
    XCTAssertEqual(
      oversizedSnip.map(\.fileName),
      ["file-0.bin", "file-1.bin", "file-2.bin", "file-3.bin", "file-4.bin"]
    )
    XCTAssertEqual(
      oversizedSnip.map(\.reason),
      Array(repeating: .snipTotalTooLarge(maximumBytes: 100), count: 5)
    )
    for fileName in oversizedSnip.map(\.fileName) {
      XCTAssertTrue(
        CloudAttachmentSetupError.unsupportedFiles(oversizedSnip)
          .localizedDescription.contains(fileName)
      )
    }
  }

  func testHundredMiBPerSnipLimitAcceptsInclusiveTotalAndRejectsOneByteOver() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileLimit = SnipSnapCloudAttachmentLimits.maximumFileBytes
    let policy = CloudAttachmentCompatibilityPolicy.openSourceDefault
    let boundary = try compatibilitySnapshot(
      in: root.appendingPathComponent("boundary"),
      sizes: [fileLimit, fileLimit, fileLimit, fileLimit]
    )

    XCTAssertTrue(
      CloudAttachmentTransferCoordinator.unsupportedFiles(
        in: boundary,
        policy: policy
      ).isEmpty
    )

    let overflow = try compatibilitySnapshot(
      in: root.appendingPathComponent("overflow"),
      sizes: [fileLimit, fileLimit, fileLimit, fileLimit, 1]
    )
    let unsupported = CloudAttachmentTransferCoordinator.unsupportedFiles(
      in: overflow,
      policy: policy
    )
    XCTAssertEqual(unsupported.count, 5)
    XCTAssertEqual(
      unsupported.map(\.reason),
      Array(
        repeating: .snipTotalTooLarge(
          maximumBytes: SnipSnapCloudAttachmentLimits.maximumAttachmentBytesPerSnip
        ),
        count: 5
      )
    )
  }

  func testCacheInstallRejectsOversizeAndCleansStagedFile() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    let bytes = Data("too large for this cache".utf8)
    try bytes.write(to: source)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    _ = try await library.perform(
      .add(
        content: "oversize",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    let namespace = namespaceValue()
    try await library.reconcileCloudAttachments(
      namespaceKey: namespace.namespaceKey,
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let stored = try await snapshot(library, namespace)
    let publication = try XCTUnwrap(stored.publications.first)
    let stagingRoot = try await library.cloudAttachmentStagingRoot(
      namespaceKey: namespace.namespaceKey
    )
    let staged = stagingRoot.appendingPathComponent("oversize/payload")
    try FileManager.default.createDirectory(
      at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try bytes.write(to: staged)

    do {
      _ = try await library.installCloudAttachmentDownload(
        namespaceKey: namespace.namespaceKey,
        attachmentID: publication.metadata.attachmentID,
        expectedPayloadIdentity: publication.metadata.payloadIdentity,
        expectedField: CloudAttachmentRecordCodec.assetField,
        download: CloudAttachmentCacheDownload(
          payloadIdentity: publication.metadata.payloadIdentity,
          field: CloudAttachmentRecordCodec.assetField,
          fileURL: staged,
          byteCount: Int64(bytes.count),
          sha256: Data(SHA256.hash(data: bytes))
        ),
        maximumBytes: Int64(bytes.count - 1),
        now: .distantPast
      )
      XCTFail("An oversize file must not enter the cache.")
    } catch {
      XCTAssertEqual(error as? CloudAttachmentStorageError, .sizeMismatch)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
  }

  func testCacheInstallRejectsPayloadReplacedDuringDownload() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    let oldBytes = Data("old payload".utf8)
    try oldBytes.write(to: source)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    _ = try await library.perform(
      .add(
        content: "race",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    let namespace = namespaceValue()
    try await library.reconcileCloudAttachments(
      namespaceKey: namespace.namespaceKey,
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let before = try await snapshot(library, namespace)
    let publication = try XCTUnwrap(before.publications.first)
    let stagingRoot = try await library.cloudAttachmentStagingRoot(
      namespaceKey: namespace.namespaceKey
    )
    let staged = stagingRoot.appendingPathComponent("race/payload")
    try FileManager.default.createDirectory(
      at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try oldBytes.write(to: staged)
    let replacementBytes = Data("new payload".utf8)
    let replacement = CloudAttachmentMetadataValue(
      attachmentID: publication.metadata.attachmentID,
      snipID: publication.metadata.snipID,
      position: publication.metadata.position,
      fileName: publication.metadata.fileName,
      contentType: publication.metadata.contentType,
      byteCount: Int64(replacementBytes.count),
      sha256: Data(SHA256.hash(data: replacementBytes)),
      payloadIdentity: CloudTextStorageIdentity(
        zoneName: "payload",
        ownerName: "owner",
        recordName: UUID().uuidString.lowercased()
      )
    )
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace.namespaceKey,
      transitions: [.remoteMetadataAccepted(
        metadata: replacement,
        metadataIdentity: publication.metadataIdentity,
        shadowData: Data(),
        systemFields: Data()
      )]
    )

    do {
      _ = try await library.installCloudAttachmentDownload(
        namespaceKey: namespace.namespaceKey,
        attachmentID: publication.metadata.attachmentID,
        expectedPayloadIdentity: publication.metadata.payloadIdentity,
        expectedField: CloudAttachmentRecordCodec.assetField,
        download: CloudAttachmentCacheDownload(
          payloadIdentity: publication.metadata.payloadIdentity,
          field: CloudAttachmentRecordCodec.assetField,
          fileURL: staged,
          byteCount: Int64(oldBytes.count),
          sha256: Data(SHA256.hash(data: oldBytes))
        ),
        maximumBytes: 1_024,
        now: .distantPast
      )
      XCTFail("A replaced payload must not enter the cache.")
    } catch {
      XCTAssertEqual(error as? CloudAttachmentStorageError, .staleTransition)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
  }

  func testTouchRemovesCachedFileWhenPublicationIsNotAvailable() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    let bytes = Data("not published yet".utf8)
    try bytes.write(to: source)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    _ = try await library.perform(
      .add(
        content: "waiting",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    let namespace = namespaceValue()
    try await library.reconcileCloudAttachments(
      namespaceKey: namespace.namespaceKey,
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let stored = try await snapshot(library, namespace)
    let publication = try XCTUnwrap(stored.publications.first)
    let stagingRoot = try await library.cloudAttachmentStagingRoot(
      namespaceKey: namespace.namespaceKey
    )
    let staged = stagingRoot.appendingPathComponent("unavailable/payload")
    try FileManager.default.createDirectory(
      at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try bytes.write(to: staged)
    let cached = try await library.installCloudAttachmentDownload(
      namespaceKey: namespace.namespaceKey,
      attachmentID: publication.metadata.attachmentID,
      expectedPayloadIdentity: publication.metadata.payloadIdentity,
      expectedField: CloudAttachmentRecordCodec.assetField,
      download: CloudAttachmentCacheDownload(
        payloadIdentity: publication.metadata.payloadIdentity,
        field: CloudAttachmentRecordCodec.assetField,
        fileURL: staged,
        byteCount: Int64(bytes.count),
        sha256: Data(SHA256.hash(data: bytes))
      ),
      maximumBytes: 1_024,
      now: .distantPast
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))

    let unavailable = try await library.touchCloudAttachmentCache(
      namespaceKey: namespace.namespaceKey,
      attachmentID: publication.metadata.attachmentID,
      now: Date(timeIntervalSince1970: 1)
    )

    XCTAssertNil(unavailable)
    XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
  }

  func testTouchRejectsSameSizeCachedFileWithChangedBytes() async throws {
    let fixture = try await makeAvailableCacheFixture(named: "touch-corrupt")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data(repeating: 0xEE, count: fixture.bytes.count).write(to: fixture.cachedURL)

    let available = try await fixture.library.touchCloudAttachmentCache(
      namespaceKey: fixture.namespace.namespaceKey,
      attachmentID: fixture.attachmentID,
      now: Date(timeIntervalSince1970: 2)
    )

    XCTAssertNil(available)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cachedURL.path))
  }

  func testSweepRejectsSameSizeCachedFileWithChangedBytes() async throws {
    let fixture = try await makeAvailableCacheFixture(named: "sweep-corrupt")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data(repeating: 0xDD, count: fixture.bytes.count).write(to: fixture.cachedURL)

    try await fixture.library.sweepCloudAttachmentCache(
      namespaceKey: fixture.namespace.namespaceKey,
      maximumBytes: 1_024
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cachedURL.path))
    let stored = try await snapshot(fixture.library, fixture.namespace)
    XCTAssertTrue(stored.cacheEntries.isEmpty)
  }

  func testPreparedLocalSourceRejectsBytesChangedAfterPublicationWasPrepared() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    try Data("original".utf8).write(to: source)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    _ = try await library.perform(
      .add(
        content: "local source",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    let namespace = namespaceValue()
    try await library.reconcileCloudAttachments(
      namespaceKey: namespace.namespaceKey,
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let stored = try await snapshot(library, namespace)
    let publication = try XCTUnwrap(stored.publications.first)
    let localURL = try XCTUnwrap(publication.localSourceURL)
    try Data("tampered".utf8).write(to: localURL)
    let coordinator = CloudAttachmentTransferCoordinator(
      library: library,
      namespace: namespace,
      payloadZone: CloudZoneID(name: "payload", ownerName: "owner"),
      transport: FakeCloudRecordTransport(server: FakeCloudServer()),
      maximumCacheBytes: 1024
    )

    do {
      _ = try await coordinator.prepare(
        attachmentID: publication.metadata.attachmentID,
        for: .preview
      )
      XCTFail("A changed local source must not be used.")
    } catch {
      XCTAssertEqual(error as? CloudAttachmentStorageError, .hashMismatch)
    }
  }

  func testDeletedPreparedLocalSourceDownloadsAcceptedCloudPayload() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    let bytes = Data("remote fallback".utf8)
    try bytes.write(to: source)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    _ = try await library.perform(
      .add(
        content: "local source",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    let namespace = namespaceValue()
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    try await library.reconcileCloudAttachments(
      namespaceKey: namespace.namespaceKey,
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: payloadZone.name,
      payloadOwnerName: payloadZone.ownerName
    )
    let prepared = try await snapshot(library, namespace)
    let publication = try XCTUnwrap(prepared.publications.first)
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
    let payloadResult = try await transport.send(CloudOutboundBatch(
      operations: [.save(try CloudAttachmentRecordCodec.payloadDraft(publication))],
      zonesToSave: [payloadZone]
    ))
    guard case .saved(let payloadSnapshot) = try XCTUnwrap(payloadResult.items.first) else {
      return XCTFail("Expected payload save")
    }
    try await transport.confirmApplied(payloadResult.id)
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace.namespaceKey,
      transitions: [.payloadAccepted(
        attachmentID: publication.metadata.attachmentID,
        expectedRevision: publication.revision,
        shadowData: payloadSnapshot.shadow.data,
        systemFields: payloadSnapshot.shadow.systemFields
      )]
    )
    let afterPayload = try await snapshot(library, namespace)
    let accepted = try XCTUnwrap(afterPayload.publications.first)
    let metadataResult = try await transport.send(CloudOutboundBatch(
      operations: [.save(try CloudAttachmentRecordCodec.metadataDraft(accepted))],
      zonesToSave: [CloudZoneID(name: "data", ownerName: "owner")]
    ))
    guard case .saved(let metadataSnapshot) = try XCTUnwrap(metadataResult.items.first) else {
      return XCTFail("Expected metadata save")
    }
    try await transport.confirmApplied(metadataResult.id)
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace.namespaceKey,
      transitions: [.metadataAccepted(
        attachmentID: accepted.metadata.attachmentID,
        expectedRevision: accepted.revision,
        shadowData: metadataSnapshot.shadow.data,
        systemFields: metadataSnapshot.shadow.systemFields
      )]
    )
    let localURL = try XCTUnwrap(accepted.localSourceURL)
    try FileManager.default.removeItem(at: localURL)
    let coordinator = CloudAttachmentTransferCoordinator(
      library: library,
      namespace: namespace,
      payloadZone: payloadZone,
      transport: transport,
      maximumCacheBytes: 1024
    )

    let downloaded = try await coordinator.prepare(
      attachmentID: publication.metadata.attachmentID,
      for: .preview
    )

    XCTAssertEqual(try Data(contentsOf: downloaded), bytes)
    XCTAssertNotEqual(downloaded.standardizedFileURL, localURL.standardizedFileURL)
  }

  func testAReorderFromAnotherDeviceIsKeptByTheDeviceThatHoldsTheFiles() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let order = [pair.second.id, pair.first.id]
    try await editDownloadedAttachments(pair, keeping: order)
    try await pair.receiver.sync()
    let published = try await snapshot(pair.receiverLibrary, pair.namespace)
    XCTAssertTrue(published.publications.allSatisfy(\.metadataAccepted))
    var acceptedCounts: [CloudRecordID: Int] = [:]
    for attachment in [pair.first, pair.second] {
      let id = CloudAttachmentRecordCodec.recordID(attachment.metadataIdentity)
      acceptedCounts[id] = await pair.server.acceptedOperationCount(for: id)
    }

    try await pair.sender.sync()
    try await pair.sender.sync()
    for (id, count) in acceptedCounts {
      let afterAdoption = await pair.server.acceptedOperationCount(for: id)
      XCTAssertEqual(afterAdoption, count, "Adopting the order must not save identical metadata.")
    }
    try await pair.receiver.fetchRemote()

    for library in [pair.senderLibrary, pair.receiverLibrary] {
      let local = try await library.checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(local.snips.first(where: { $0.id == pair.snipID })?.attachments.map(\.id), order)
    }
    let adopted = try await snapshot(pair.senderLibrary, pair.namespace)
    for (position, attachment) in [pair.second, pair.first].enumerated() {
      let row = try publication(of: attachment.id, in: adopted)
      XCTAssertEqual(row.metadata.position, position)
      XCTAssertTrue(row.metadataAccepted)
      XCTAssertNil(row.lastFailure)
      let remote = await pair.server.fullSnapshot(
        for: CloudAttachmentRecordCodec.recordID(attachment.metadataIdentity)
      )
      XCTAssertEqual(remote?.encryptedFields["position"], .int64(Int64(position)))
    }
    let metadataIDs = [pair.first.metadataIdentity, pair.second.metadataIdentity]
      .map(CloudAttachmentRecordCodec.recordID)
    for store in [pair.senderStore, pair.receiverStore] {
      let next = try await store.pendingChanges()
      XCTAssertFalse(next.operations.contains(where: { metadataIDs.contains($0.id) }))
    }
  }

  func testANewRemoteAttachmentCanPrecedeAnExistingDownloadedAttachment() async throws {
    let first = try await makeAttachmentClient(fileNames: ["existing"])
    defer { try? FileManager.default.removeItem(at: first.root) }
    try await first.sync.sync()
    try await first.sync.sync()
    let second = try attachmentClient(root: first.root,
      storeURL: first.root.appendingPathComponent("other.store"),
      namespace: first.namespace, server: first.server, snipID: first.snipID)
    try await second.sync.fetchRemote()
    let local = try await first.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == first.snipID }))
    let existingID = try XCTUnwrap(snip.attachments.first).id
    let source = first.root.appendingPathComponent("new.txt")
    try Data("new attachment".utf8).write(to: source)
    let added = try await first.library.perform(.editAttachments(
      snipID: first.snipID, content: snip.content,
      edits: [.added(sourceURL: source), .existing(attachmentID: existingID)],
      expectedUpdatedAt: snip.updatedAt, now: Date(timeIntervalSince1970: 2)
    ), sortedBy: .manual)
    let addedSnip = try XCTUnwrap(added.snapshot.snips.first(where: { $0.id == first.snipID }))
    let newID = try XCTUnwrap(addedSnip.attachments.first(where: { $0.fileName == "new.txt" })).id
    try await first.sync.sync()
    try await first.sync.sync()

    try await second.sync.fetchRemote()

    let order = try await assertSettledAttachmentOrder([existingID, newID], between: first, and: second)
    XCTAssertEqual(order, [newID, existingID])
  }

  func testRetryingAPartialAttachmentFetchPreservesTheServersSparsePositions() async throws {
    let first = try await makeAttachmentClient(fileNames: ["a", "b"])
    defer { try? FileManager.default.removeItem(at: first.root) }
    try await first.sync.sync()
    try await first.sync.sync()
    let published = try await snapshot(first.library, first.namespace)
    let a = try XCTUnwrap(published.publications.first(where: { $0.metadata.fileName == "a.txt" }))
    let b = try XCTUnwrap(published.publications.first(where: { $0.metadata.fileName == "b.txt" }))
    let receiver = try attachmentClient(root: first.root,
      storeURL: first.root.appendingPathComponent("receiver.store"),
      namespace: first.namespace, server: first.server, snipID: first.snipID)
    await receiver.transport.failNextFetchedItem(
      CloudAttachmentRecordCodec.recordID(a.metadataIdentity), failure: .retryable
    )

    try await receiver.sync.fetchRemote()

    let partial = try await snapshot(receiver.library, receiver.namespace)
    XCTAssertEqual(try publication(of: b.metadata.attachmentID, in: partial).metadata.position, 1,
      "A partial fetch must retain B's cloud coordinate.")
    let partialPositions = try await receiver.library.storedAttachmentReferencePositions(for: first.snipID)
    XCTAssertEqual(partialPositions, [b.metadata.attachmentID: 0], "Stored positions must be local order.")

    try await receiver.sync.fetchRemote()

    let local = try await receiver.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == first.snipID }))
    XCTAssertEqual(snip.attachments.map(\.id), [a.metadata.attachmentID, b.metadata.attachmentID])
    let positions = try await receiver.library.storedAttachmentReferencePositions(for: first.snipID)
    XCTAssertEqual(positions, [a.metadata.attachmentID: 0, b.metadata.attachmentID: 1])
    let next = try await receiver.store.pendingChanges()
    XCTAssertFalse(next.operations.contains(where: { operation in
      guard case .save(let draft) = operation else { return false }
      return draft.recordType == CloudAttachmentRecordCodec.metadataRecordType
    }), "Retrying a fetch must not create an attachment reorder.")
    for (position, row) in [a, b].enumerated() {
      let id = CloudAttachmentRecordCodec.recordID(row.metadataIdentity)
      let remote = await first.server.fullSnapshot(for: id)
      XCTAssertEqual(remote?.encryptedFields["position"], .int64(Int64(position)))
      let saves = await first.server.acceptedOperationCount(for: id)
      XCTAssertEqual(saves, 1)
    }
  }

  func testConcurrentAttachmentReordersPersistUniquePositionsAndAllowALaterRemoteReorder() async throws {
    let first = try await makeAttachmentClient(fileNames: ["a", "b", "c"])
    defer { try? FileManager.default.removeItem(at: first.root) }
    try await first.sync.sync()
    try await first.sync.sync()
    let published = try await snapshot(first.library, first.namespace)
    let a = try XCTUnwrap(published.publications.first(where: { $0.metadata.fileName == "a.txt" }))
      .metadata.attachmentID
    let b = try XCTUnwrap(published.publications.first(where: { $0.metadata.fileName == "b.txt" }))
      .metadata.attachmentID
    let c = try XCTUnwrap(published.publications.first(where: { $0.metadata.fileName == "c.txt" }))
      .metadata.attachmentID
    XCTAssertTrue(published.publications.allSatisfy(\.metadataAccepted))
    XCTAssertEqual(published.publications.sorted { $0.metadata.position < $1.metadata.position }
      .map(\.metadata.attachmentID), [a, b, c])
    let second = try attachmentClient(
      root: first.root,
      storeURL: first.root.appendingPathComponent("other.store"),
      namespace: first.namespace,
      server: first.server,
      snipID: first.snipID
    )
    try await second.sync.fetchRemote()
    try await keepAttachments([b, a, c], ofSnip: first.snipID, in: first.library)
    try await keepAttachments([c, a, b], ofSnip: second.snipID, in: second.library)
    try await second.sync.sync()

    for _ in 0..<2 {
      try await first.sync.sync()
      try await second.sync.sync()
    }

    let attachmentIDs: Set<UUID> = [a, b, c]
    let settledOrder = try await assertSettledAttachmentOrder(attachmentIDs, between: first, and: second)
    XCTAssertEqual(settledOrder, [b, a, c], "D1 reaches iCloud last, so its whole order must win.")
    let latestOrder = settledOrder == [c, b, a] ? [b, c, a] : [c, b, a]
    try await keepAttachments(latestOrder, ofSnip: second.snipID, in: second.library)
    try await second.sync.sync()
    for _ in 0..<2 {
      try await first.sync.sync()
      try await second.sync.sync()
    }

    let afterRemoteReorder = try await assertSettledAttachmentOrder(attachmentIDs, between: first, and: second)
    XCTAssertEqual(afterRemoteReorder, latestOrder, "D2's later order must survive D1's fetch and reconcile.")
  }

  func testConcurrentDisjointAttachmentSwapsKeepTheLastDevicesWholeOrder() async throws {
    let first = try await makeAttachmentClient(fileNames: ["a", "b", "c", "d"])
    defer { try? FileManager.default.removeItem(at: first.root) }
    try await first.sync.sync()
    try await first.sync.sync()
    let published = try await snapshot(first.library, first.namespace)
    let order = published.publications.sorted { $0.metadata.position < $1.metadata.position }
      .map(\.metadata.attachmentID)
    XCTAssertEqual(order.count, 4)
    let second = try attachmentClient(root: first.root,
      storeURL: first.root.appendingPathComponent("other.store"),
      namespace: first.namespace, server: first.server, snipID: first.snipID)
    try await second.sync.fetchRemote()
    let localOrder = [order[1], order[0], order[2], order[3]]
    let remoteOrder = [order[0], order[1], order[3], order[2]]
    try await keepAttachments(localOrder, ofSnip: first.snipID, in: first.library)
    try await keepAttachments(remoteOrder, ofSnip: second.snipID, in: second.library)
    try await second.sync.sync()

    for _ in 0..<2 {
      try await first.sync.sync()
      try await second.sync.sync()
    }

    let settled = try await assertSettledAttachmentOrder(Set(order), between: first, and: second)
    XCTAssertEqual(settled, localOrder, "Disjoint swaps still edit the same snip-level order field.")
  }

  func testALaterRemoteReorderRestoresTheCoordinatesOfAnUnadoptedSibling() async throws {
    let first = try await makeAttachmentClient(fileNames: ["one", "two", "three"])
    defer { try? FileManager.default.removeItem(at: first.root) }
    let initial = try await first.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(initial.snips.first(where: { $0.id == first.snipID }))
    let ids = snip.attachments.map(\.id).sorted { $0.uuidString < $1.uuidString }
    XCTAssertEqual(ids.count, 3)
    let c = ids[0]
    let a = ids[1]
    let b = ids[2]
    try await keepAttachments([a, b, c], ofSnip: first.snipID, in: first.library)
    try await first.sync.sync()
    try await first.sync.sync()
    let second = try attachmentClient(root: first.root,
      storeURL: first.root.appendingPathComponent("other.store"),
      namespace: first.namespace, server: first.server, snipID: first.snipID)
    try await second.sync.fetchRemote()
    // A mixed pending/adopted commit can leave these raw coordinates after publishing A0/B1/C2.
    try await first.library.setStoredAttachmentReferencePositions([a: 0, b: 0, c: 1], for: first.snipID)
    try await keepAttachments([b, a, c], ofSnip: second.snipID, in: second.library)
    try await second.sync.sync()

    for _ in 0..<2 {
      try await first.sync.sync()
      try await second.sync.sync()
    }

    let settled = try await assertSettledAttachmentOrder(Set(ids), between: first, and: second)
    XCTAssertEqual(settled, [b, a, c], "Adoption must also restore the unchanged sibling's stored coordinate.")
  }

  func testAPendingReorderKeepsTheWholeSnipOrderBesideAnAdoptedSibling() async throws {
    let clients = try await makeAttachmentEditClients()
    let h = clients.holder
    let d = clients.downloaded
    defer { try? FileManager.default.removeItem(at: h.root) }
    let order = AttachmentMatrixMember.localOrder.map(\.id)
    try await keepAttachments(order, ofSnip: h.snipID, in: h.library)
    _ = try await h.store.pendingChanges()
    for member in [AttachmentMatrixMember.a, .b] {
      await h.transport.failNextSentItem(CloudAttachmentRecordCodec.recordID(
        CloudTextStorageIdentity(zoneName: "data", ownerName: "owner",
          recordName: "a-\(member.id.uuidString.lowercased())")), failure: .retryable)
    }
    try await h.sync.sendPending()
    try await keepAttachments(AttachmentMatrixMember.remoteOrder.map(\.id), ofSnip: d.snipID, in: d.library)
    try await d.sync.sync()

    for _ in 0..<2 {
      try await h.sync.sync()
      try await d.sync.sync()
    }

    let settled = try await assertSettledAttachmentOrder(Set(order), between: h, and: d)
    XCTAssertEqual(settled, order)
  }

  func testReinsertingAnUnrecordedDownloadRemovalKeepsTheOriginalOrderWithoutASave() async throws {
    let clients = try await makeAttachmentEditClients()
    let h = clients.holder
    let d = clients.downloaded
    defer { try? FileManager.default.removeItem(at: h.root) }
    let order = AttachmentMatrixMember.initial.map(\.id)
    try await keepAttachments([AttachmentMatrixMember.b.id, AttachmentMatrixMember.c.id],
      ofSnip: d.snipID, in: d.library)
    let initial = try await snapshot(h.library, h.namespace)
    var acceptedCounts: [CloudRecordID: Int] = [:]
    for row in initial.publications {
      let id = CloudAttachmentRecordCodec.recordID(row.metadataIdentity)
      acceptedCounts[id] = await h.server.acceptedOperationCount(for: id)
    }

    try await d.sync.fetchRemote()

    let restored = try await assertSettledAttachmentOrder(Set(order), between: h, and: d)
    XCTAssertEqual(restored, order)
    try await d.sync.sync()
    try await h.sync.fetchRemote()
    let afterSync = try await assertSettledAttachmentOrder(Set(order), between: h, and: d)
    XCTAssertEqual(afterSync, order)
    for (id, count) in acceptedCounts {
      let after = await h.server.acceptedOperationCount(for: id)
      XCTAssertEqual(after, count, "Reinsertion must not publish a reorder.")
    }
  }

  func testAnUnreconciledAppendKeepsARemoteReorderOfSharedAttachments() async throws {
    let clients = try await makeAttachmentEditClients(attachmentCount: 2)
    let h = clients.holder
    let d = clients.downloaded
    defer { try? FileManager.default.removeItem(at: h.root) }
    try await appendAttachment(.n, to: h)
    try await keepAttachments([AttachmentMatrixMember.b.id, AttachmentMatrixMember.a.id],
      ofSnip: d.snipID, in: d.library)
    try await d.sync.sync()

    for _ in 0..<2 {
      try await h.sync.sync()
      try await d.sync.sync()
    }

    let order = [AttachmentMatrixMember.b.id, AttachmentMatrixMember.a.id, AttachmentMatrixMember.n.id]
    let settled = try await assertSettledAttachmentOrder(Set(order), between: h, and: d)
    XCTAssertEqual(settled, order)
  }

  func testARemoteReorderOfSharedAttachmentsSurvivesAnUnreconciledLocalRemoval() async throws {
    let clients = try await makeAttachmentEditClients()
    let h = clients.holder
    let d = clients.downloaded
    defer { try? FileManager.default.removeItem(at: h.root) }
    try await keepAttachments([AttachmentMatrixMember.b.id, AttachmentMatrixMember.c.id],
      ofSnip: h.snipID, in: h.library)
    try await keepAttachments([AttachmentMatrixMember.a.id, AttachmentMatrixMember.c.id, AttachmentMatrixMember.b.id],
      ofSnip: d.snipID, in: d.library)
    try await d.sync.sync()

    for _ in 0..<2 {
      try await h.sync.sync()
      try await d.sync.sync()
    }

    let expected = [AttachmentMatrixMember.c.id, AttachmentMatrixMember.b.id]
    for client in [h, d] {
      let local = try await client.library.checkedSnapshot(sortedBy: .manual)
      let snip = try XCTUnwrap(local.snips.first(where: { $0.id == client.snipID }))
      XCTAssertEqual(snip.attachments.map(\.id), expected)
      let storage = try await snapshot(client.library, client.namespace)
      XCTAssertEqual(Set(storage.publications.map(\.metadata.attachmentID)), Set(expected))
      for (position, id) in expected.enumerated() {
        let row = try publication(of: id, in: storage)
        let remote = await h.server.fullSnapshot(for: CloudAttachmentRecordCodec.recordID(row.metadataIdentity))
        XCTAssertEqual(remote?.encryptedFields["position"], .int64(Int64(position)))
      }
      let next = try await client.store.pendingChanges()
      XCTAssertFalse(next.operations.contains(where: { operation in
        guard case .save(let draft) = operation else { return false }
        return draft.recordType == CloudAttachmentRecordCodec.metadataRecordType
      }))
    }
    let removedID = CloudRecordID(zone: CloudZoneID(name: "data", ownerName: "owner"),
      name: "a-\(AttachmentMatrixMember.a.id.uuidString.lowercased())")
    let removed = await h.server.fullSnapshot(for: removedID)
    XCTAssertNil(removed)
  }

  func testARemoteRenameSurvivesRemovingALocalSiblingBeforeReconcile() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await keepAttachments([pair.second.id], ofSnip: pair.snipID, in: pair.senderLibrary)
    try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
      to: "renamed remotely.txt", in: pair.receiverLibrary)
    try await pair.receiver.sync()

    try await pair.sender.sync()
    try await pair.receiver.fetchRemote()

    let expected = [(id: pair.second.id, fileName: "renamed remotely.txt")]
    try await assertSyncedAttachments(expected, in: pair)
    let removed = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(pair.first.metadataIdentity)
    )
    XCTAssertNil(removed)
    try await pair.receiver.sync()
    try await assertSyncedAttachments(expected, in: pair)
  }

  func testARemoteRenameSurvivesReorderingLocalSiblingsBeforeReconcile() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await keepAttachments([pair.second.id, pair.first.id], ofSnip: pair.snipID, in: pair.senderLibrary)
    try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
      to: "renamed remotely.txt", in: pair.receiverLibrary)
    try await pair.receiver.sync()

    try await pair.sender.sync()
    try await pair.receiver.fetchRemote()

    let expected = [(id: pair.second.id, fileName: "renamed remotely.txt"),
      (id: pair.first.id, fileName: "first.txt")]
    try await assertSyncedAttachments(expected, in: pair)
    try await pair.receiver.sync()
    try await assertSyncedAttachments(expected, in: pair)
  }

  func testARemoteRenameSurvivesAddingALocalSiblingBeforeReconcile() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let addedURL = pair.root.appendingPathComponent("third.txt")
    try Data("third attachment".utf8).write(to: addedURL)
    let local = try await pair.senderLibrary.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == pair.snipID }))
    let added = try await pair.senderLibrary.perform(.editAttachments(
      snipID: pair.snipID,
      content: snip.content,
      edits: [.existing(attachmentID: pair.first.id), .existing(attachmentID: pair.second.id),
        .added(sourceURL: addedURL)],
      expectedUpdatedAt: snip.updatedAt,
      now: Date(timeIntervalSince1970: 2)
    ), sortedBy: .manual)
    let addedSnip = try XCTUnwrap(added.snapshot.snips.first(where: { $0.id == pair.snipID }))
    let thirdID = try XCTUnwrap(addedSnip.attachments.first(where: { $0.fileName == "third.txt" })).id
    try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
      to: "renamed remotely.txt", in: pair.receiverLibrary)
    try await pair.receiver.sync()

    try await pair.sender.sync()
    try await pair.sender.sync()
    try await pair.receiver.fetchRemote()

    let expected = [(id: pair.first.id, fileName: "first.txt"),
      (id: pair.second.id, fileName: "renamed remotely.txt"),
      (id: thirdID, fileName: "third.txt")]
    try await assertSyncedAttachments(expected, in: pair)
    try await pair.receiver.sync()
    try await assertSyncedAttachments(expected, in: pair)
  }

  func testARemoteRenameSurvivesADownloadedSiblingBeingReinsertedAfterLocalRemoval() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await editDownloadedAttachments(pair, keeping: [pair.second.id])
    try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
      to: "renamed on 1.txt", in: pair.senderLibrary)
    try await pair.sender.sync()
    var acceptedCounts: [CloudRecordID: Int] = [:]
    for attachment in [pair.first, pair.second] {
      let id = CloudAttachmentRecordCodec.recordID(attachment.metadataIdentity)
      acceptedCounts[id] = await pair.server.acceptedOperationCount(for: id)
    }

    try await pair.receiver.sync()
    try await pair.sender.fetchRemote()

    let expected = [(id: pair.first.id, fileName: "first.txt"),
      (id: pair.second.id, fileName: "renamed on 1.txt")]
    try await assertSyncedAttachments(expected, in: pair)
    let positions = try await pair.receiverLibrary.storedAttachmentReferencePositions(for: pair.snipID)
    XCTAssertEqual(positions, [pair.first.id: 0, pair.second.id: 1])
    try await pair.receiver.sync()
    try await pair.sender.fetchRemote()
    try await assertSyncedAttachments(expected, in: pair)
    for store in [pair.senderStore, pair.receiverStore] {
      let next = try await store.pendingChanges()
      XCTAssertFalse(next.operations.contains(where: { operation in
        guard case .save(let draft) = operation else { return false }
        return draft.recordType == CloudAttachmentRecordCodec.metadataRecordType
      }))
    }
    for (id, count) in acceptedCounts {
      let after = await pair.server.acceptedOperationCount(for: id)
      XCTAssertEqual(after, count, "The 8c reinsert must retain its original place without a metadata save.")
    }
  }

  func testTheLastAttachmentRenameToReachCloudKitWinsInEitherOrder() async throws {
    for senderPublishesLast in [true, false] {
      let pair = try await makeDownloadedAttachmentPair()
      defer { try? FileManager.default.removeItem(at: pair.root) }
      try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
        to: "renamed on 1.txt", in: pair.senderLibrary)
      try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
        to: "renamed on 2.txt", in: pair.receiverLibrary)
      let first = senderPublishesLast ? pair.receiver : pair.sender
      let last = senderPublishesLast ? pair.sender : pair.receiver

      try await first.sync()
      try await last.sync()
      try await first.fetchRemote()
      try await last.fetchRemote()

      let winner = senderPublishesLast ? "renamed on 1.txt" : "renamed on 2.txt"
      try await assertSyncedAttachments([
        (id: pair.first.id, fileName: "first.txt"), (id: pair.second.id, fileName: winner),
      ], in: pair)
    }
  }

  func testAReconciledReorderKeepsItsOrderAndTakesARemoteRenameWhileAwaitingAcknowledgement() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await keepAttachments([pair.second.id, pair.first.id], ofSnip: pair.snipID, in: pair.senderLibrary)
    for attachment in [pair.first, pair.second] {
      await pair.senderTransport.failNextSentItem(
        CloudAttachmentRecordCodec.recordID(attachment.metadataIdentity), failure: .retryable
      )
    }
    try await pair.sender.sendPending()
    let waiting = try await snapshot(pair.senderLibrary, pair.namespace)
    let reordered = try publication(of: pair.second.id, in: waiting)
    XCTAssertFalse(reordered.metadataAccepted)
    XCTAssertEqual(reordered.metadata.position, 0)
    XCTAssertEqual(reordered.lastFailure, .retryable)
    try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
      to: "renamed on 2.txt", in: pair.receiverLibrary)
    try await pair.receiver.sync()

    try await pair.sender.fetchRemote()

    let keptStorage = try await snapshot(pair.senderLibrary, pair.namespace)
    let kept = try publication(of: pair.second.id, in: keptStorage)
    XCTAssertFalse(kept.metadataAccepted)
    XCTAssertEqual(kept.metadata.position, 0)
    XCTAssertEqual(kept.metadata.fileName, "renamed on 2.txt")
    let remote = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(pair.second.metadataIdentity)
    )
    XCTAssertEqual(kept.metadataShadowData, try XCTUnwrap(remote).shadow.data)
    try await pair.sender.sendPending()
    try await pair.receiver.sync()
    try await pair.sender.fetchRemote()
    try await assertSyncedAttachments([
      (id: pair.second.id, fileName: "renamed on 2.txt"), (id: pair.first.id, fileName: "first.txt"),
    ], in: pair)
  }

  func testARevertedUnsentRenameTakesANewerRemoteRename() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
      to: "renamed on 2.txt", in: pair.receiverLibrary)
    _ = try await pair.receiverStore.pendingChanges()
    try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
      to: pair.second.fileName, in: pair.receiverLibrary)
    try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
      to: "renamed on 1.txt", in: pair.senderLibrary)
    try await pair.sender.sync()

    try await pair.receiver.sync()
    try await pair.sender.fetchRemote()

    try await assertSyncedAttachments([
      (id: pair.first.id, fileName: "first.txt"), (id: pair.second.id, fileName: "renamed on 1.txt"),
    ], in: pair)
    for store in [pair.senderStore, pair.receiverStore] {
      let next = try await store.pendingChanges()
      XCTAssertFalse(plansMetadataSave(for: pair.second, in: next), "A reverted rename must not resend the old name.")
    }
  }

  func testAnUnreadableMetadataShadowKeepsAPendingAttachmentEdit() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
      to: "kept on 2.txt", in: pair.receiverLibrary)
    _ = try await pair.receiverStore.pendingChanges()
    let pendingStorage = try await snapshot(pair.receiverLibrary, pair.namespace)
    let pending = try publication(of: pair.second.id, in: pendingStorage)
    try await pair.receiverLibrary.commitCloudAttachmentTransitions(
      namespaceKey: pair.namespace.namespaceKey,
      transitions: [.metadataConflict(attachmentID: pair.second.id, expectedRevision: pending.revision,
        shadowData: Data("not-a-cloud-record-shadow".utf8), systemFields: Data())]
    )
    try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
      to: "renamed on 1.txt", in: pair.senderLibrary)
    try await pair.sender.sync()
    let remote = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(pair.second.metadataIdentity)
    )
    let fetched = try XCTUnwrap(remote)

    try await pair.receiver.fetchRemote()

    let keptStorage = try await snapshot(pair.receiverLibrary, pair.namespace)
    let kept = try publication(of: pair.second.id, in: keptStorage)
    XCTAssertFalse(kept.metadataAccepted)
    XCTAssertEqual(kept.metadata.fileName, "kept on 2.txt", "Without a readable base, the pending edit keeps its whole record.")
    XCTAssertEqual(kept.metadataShadowData, fetched.shadow.data)
    try await pair.receiver.sync()
    try await pair.sender.fetchRemote()
    try await assertSyncedAttachments([
      (id: pair.first.id, fileName: "first.txt"), (id: pair.second.id, fileName: "kept on 2.txt"),
    ], in: pair)
  }

  func testAConflictingAttachmentSaveKeepsBothDevicesEditsToDifferentFields() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await keepAttachments([pair.second.id, pair.first.id], ofSnip: pair.snipID, in: pair.senderLibrary)
    try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
      to: "renamed on 2.txt", in: pair.receiverLibrary)
    try await pair.receiver.sync()

    // Sending without a fetch saves the reorder against the base the rename replaced.
    try await pair.sender.sendPending()

    let conflicted = try await snapshot(pair.senderLibrary, pair.namespace)
    XCTAssertFalse(try publication(of: pair.second.id, in: conflicted).metadataAccepted)
    let server = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(pair.second.metadataIdentity)
    )
    XCTAssertEqual(server?.encryptedFields["fileName"], .string("renamed on 2.txt"), "CloudKit must reject the stale save.")
    try await pair.sender.sendPending()
    try await pair.receiver.sync()
    try await pair.sender.fetchRemote()

    try await assertSyncedAttachments([
      (id: pair.second.id, fileName: "renamed on 2.txt"), (id: pair.first.id, fileName: "first.txt"),
    ], in: pair)
    for store in [pair.senderStore, pair.receiverStore] {
      let next = try await store.pendingChanges()
      XCTAssertFalse(plansMetadataSave(for: pair.first, in: next))
      XCTAssertFalse(plansMetadataSave(for: pair.second, in: next))
    }
  }

  func testAnUnsentRenameOnTheDeviceHoldingTheFilesPublishesAgainstANewerRemoteRename() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
      to: "kept on 1.txt", in: pair.senderLibrary)
    _ = try await pair.senderStore.pendingChanges()
    try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
      to: "renamed on 2.txt", in: pair.receiverLibrary)
    try await pair.receiver.sync()
    let remote = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(pair.second.metadataIdentity)
    )
    let fetched = try XCTUnwrap(remote)

    try await pair.sender.fetchRemote()

    let storage = try await snapshot(pair.senderLibrary, pair.namespace)
    let kept = try publication(of: pair.second.id, in: storage)
    XCTAssertFalse(kept.metadataAccepted)
    XCTAssertEqual(kept.metadata.fileName, "kept on 1.txt")
    XCTAssertEqual(kept.metadataShadowData, fetched.shadow.data)
    let localURL = try XCTUnwrap(kept.localSourceURL)
    XCTAssertEqual(try Data(contentsOf: localURL), pair.second.bytes)
    let outbound = try await pair.senderStore.pendingChanges()
    let operation = try XCTUnwrap(outbound.operations.first(where: {
      $0.id == CloudAttachmentRecordCodec.recordID(pair.second.metadataIdentity)
    }))
    guard case .save(let draft) = operation else { return XCTFail("The kept edit must save metadata.") }
    XCTAssertEqual(draft.base, fetched.shadow)
    XCTAssertEqual(draft.encryptedFields["fileName"], .string("kept on 1.txt"))
    try await pair.sender.sendPending()
    try await pair.receiver.sync()
    try await pair.sender.fetchRemote()
    try await assertSyncedAttachments([
      (id: pair.first.id, fileName: "first.txt"), (id: pair.second.id, fileName: "kept on 1.txt"),
    ], in: pair)
  }

  func testAFetchedBaseClearsATerminalFailureAndRetriesTheKeptAttachmentEdit() async throws {
    for failure in [CloudAttachmentFailure.updateRequired, .accessDenied] {
      let pair = try await makeDownloadedAttachmentPair()
      defer { try? FileManager.default.removeItem(at: pair.root) }
      try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
        to: "kept on 2.txt", in: pair.receiverLibrary)
      _ = try await pair.receiverStore.pendingChanges()
      let pendingStorage = try await snapshot(pair.receiverLibrary, pair.namespace)
      let pending = try publication(of: pair.second.id, in: pendingStorage)
      try await pair.receiverLibrary.commitCloudAttachmentTransitions(
        namespaceKey: pair.namespace.namespaceKey,
        transitions: [.operationFailed(attachmentID: pair.second.id,
          expectedRevision: pending.revision, failure: failure)]
      )
      let failedStorage = try await snapshot(pair.receiverLibrary, pair.namespace)
      XCTAssertEqual(try publication(of: pair.second.id, in: failedStorage).lastFailure, failure)
      let blocked = try await pair.receiverStore.pendingChanges()
      XCTAssertFalse(plansMetadataSave(for: pair.second, in: blocked))
      try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
        to: "renamed on 1.txt", in: pair.senderLibrary)
      try await pair.sender.sync()
      let remote = await pair.server.fullSnapshot(
        for: CloudAttachmentRecordCodec.recordID(pair.second.metadataIdentity)
      )
      let fetched = try XCTUnwrap(remote)

      try await pair.receiver.fetchRemote()

      let keptStorage = try await snapshot(pair.receiverLibrary, pair.namespace)
      let kept = try publication(of: pair.second.id, in: keptStorage)
      XCTAssertNil(kept.lastFailure)
      XCTAssertFalse(kept.metadataAccepted)
      XCTAssertEqual(kept.metadata.fileName, "kept on 2.txt")
      XCTAssertEqual(kept.metadataShadowData, fetched.shadow.data)
      let outbound = try await pair.receiverStore.pendingChanges()
      let operation = try XCTUnwrap(outbound.operations.first(where: {
        $0.id == CloudAttachmentRecordCodec.recordID(pair.second.metadataIdentity)
      }))
      guard case .save(let draft) = operation else { return XCTFail("The kept edit must retry its save.") }
      XCTAssertEqual(draft.base, fetched.shadow)
      XCTAssertEqual(draft.encryptedFields["fileName"], .string("kept on 2.txt"))
      try await pair.receiver.sendPending()
      try await pair.sender.fetchRemote()
      try await pair.receiver.fetchRemote()
      try await assertSyncedAttachments([
        (id: pair.first.id, fileName: "first.txt"), (id: pair.second.id, fileName: "kept on 2.txt"),
      ], in: pair)
    }
  }

  func testARemoteContentTypeSurvivesALocalRenameBeforeReconcile() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await renameAttachment(ofSnip: pair.snipID, attachmentID: pair.second.id,
      to: "renamed locally.txt", in: pair.senderLibrary)
    var remoteSnips = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual).snips
    let snipIndex = try XCTUnwrap(remoteSnips.firstIndex(where: { $0.id == pair.snipID }))
    let attachmentIndex = try XCTUnwrap(remoteSnips[snipIndex].attachments.firstIndex(where: {
      $0.id == pair.second.id
    }))
    XCTAssertNotEqual(remoteSnips[snipIndex].attachments[attachmentIndex].contentType, "public.json")
    remoteSnips[snipIndex].attachments[attachmentIndex].contentType = "public.json"
    _ = try await pair.receiverLibrary.perform(.replaceAll(remoteSnips), sortedBy: .manual)
    try await pair.receiver.sync()

    try await pair.sender.sync()
    try await pair.receiver.fetchRemote()

    try await assertSyncedAttachments([
      (id: pair.first.id, fileName: "first.txt"),
      (id: pair.second.id, fileName: "renamed locally.txt"),
    ], in: pair)
    for library in [pair.senderLibrary, pair.receiverLibrary] {
      let local = try await library.checkedSnapshot(sortedBy: .manual)
      let snip = try XCTUnwrap(local.snips.first(where: { $0.id == pair.snipID }))
      XCTAssertEqual(snip.attachments.first(where: { $0.id == pair.second.id })?.contentType, "public.json")
    }
    let remote = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(pair.second.metadataIdentity)
    )
    XCTAssertEqual(remote?.encryptedFields["contentType"], .string("public.json"))
  }

  func testARenameFromAnotherDeviceIsShownByTheDeviceThatHoldsTheFile() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await renameAttachment(ofSnip: pair.snipID, to: "renamed on 2.txt", in: pair.receiverLibrary)
    try await pair.receiver.sync()

    try await pair.sender.sync()
    try await pair.sender.sync()

    let local = try await pair.senderLibrary.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == pair.snipID }))
    XCTAssertEqual(snip.attachments.first(where: { $0.id == pair.first.id })?.fileName, "renamed on 2.txt")
    let localURL = try XCTUnwrap(local.attachmentURLs[pair.first.id])
    XCTAssertEqual(try Data(contentsOf: localURL), pair.first.bytes)
    let remote = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(pair.first.metadataIdentity)
    )
    XCTAssertEqual(remote?.encryptedFields["fileName"], .string("renamed on 2.txt"))
  }

  func testALocalReorderOfDownloadedAttachmentsSurvivesACommitBeforeReconcile() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let order = [pair.second.id, pair.first.id]
    try await editDownloadedAttachments(pair, keeping: order)
    try await editText(ofSnip: pair.snipID, to: "remote text commit", in: pair.senderLibrary)
    try await pair.sender.sync()

    try await pair.receiver.fetchRemote()

    let local = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == pair.snipID }))
    XCTAssertEqual(snip.content, "remote text commit")
    XCTAssertEqual(snip.attachments.map(\.id), order)
    let batch = try await pair.receiverStore.pendingChanges()
    XCTAssertTrue(plansMetadataSave(for: pair.first, in: batch))
    XCTAssertTrue(plansMetadataSave(for: pair.second, in: batch))
    try await pair.receiver.sync()
    for (position, attachment) in [pair.second, pair.first].enumerated() {
      let remote = await pair.server.fullSnapshot(
        for: CloudAttachmentRecordCodec.recordID(attachment.metadataIdentity)
      )
      XCTAssertEqual(remote?.encryptedFields["position"], .int64(Int64(position)))
    }
  }

  func testALocalRenameOfADownloadedAttachmentSurvivesACommitBeforeReconcile() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await renameAttachment(ofSnip: pair.snipID, to: "renamed here.txt", in: pair.receiverLibrary)
    try await editText(ofSnip: pair.snipID, to: "remote text commit", in: pair.senderLibrary)
    try await pair.sender.sync()

    try await pair.receiver.fetchRemote()

    let local = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == pair.snipID }))
    XCTAssertEqual(snip.content, "remote text commit")
    XCTAssertEqual(snip.attachments.first(where: { $0.id == pair.first.id })?.fileName, "renamed here.txt")
    let batch = try await pair.receiverStore.pendingChanges()
    XCTAssertTrue(plansMetadataSave(for: pair.first, in: batch))
    try await pair.receiver.sync()
    let remote = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(pair.first.metadataIdentity)
    )
    XCTAssertEqual(remote?.encryptedFields["fileName"], .string("renamed here.txt"))
  }

  func testAnUnsentRenameOnADownloadOnlyDeviceGoesOutAgainstANewerRemoteRename() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await renameAttachment(ofSnip: pair.snipID, to: "renamed on 2.txt", in: pair.receiverLibrary)
    _ = try await pair.receiverStore.pendingChanges()
    try await renameAttachment(ofSnip: pair.snipID, to: "renamed on 1.txt", in: pair.senderLibrary)
    try await pair.sender.sync()

    try await pair.receiver.fetchRemote()

    let local = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(
      local.snips.first(where: { $0.id == pair.snipID })?.attachments.first?.fileName,
      "renamed on 2.txt"
    )
    let storage = try await snapshot(pair.receiverLibrary, pair.namespace)
    let pending = try publication(of: pair.first.id, in: storage)
    XCTAssertFalse(pending.metadataAccepted)
    let remote = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(pair.first.metadataIdentity)
    )
    XCTAssertEqual(pending.metadataShadowData, try XCTUnwrap(remote).shadow.data)
    try await pair.receiver.sync()
    let saved = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(pair.first.metadataIdentity)
    )
    XCTAssertEqual(saved?.encryptedFields["fileName"], .string("renamed on 2.txt"))
    try await pair.sender.sync()
    let senderLocal = try await pair.senderLibrary.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(
      senderLocal.snips.first(where: { $0.id == pair.snipID })?.attachments.first?.fileName,
      "renamed on 2.txt"
    )
  }

  func testFetchingThisDevicesOwnEarlierSaveKeepsALaterEditOnADownloadOnlyDevice() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await renameAttachment(ofSnip: pair.snipID, to: "b.txt", in: pair.receiverLibrary)
    let outbound = try await pair.receiverStore.pendingChanges()
    let sent = try await pair.assetFetches.send(outbound)
    try await renameAttachment(ofSnip: pair.snipID, to: "c.txt", in: pair.receiverLibrary)
    _ = try await pair.receiverStore.pendingChanges()
    try await pair.receiverStore.stage(.sent(sent), outbound: outbound)
    try await pair.receiverStore.applyStaged(sent.id)
    try await pair.assetFetches.confirmApplied(sent.id)

    try await pair.receiver.fetchRemote()

    let local = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(local.snips.first(where: { $0.id == pair.snipID })?.attachments.first?.fileName, "c.txt")
    let storage = try await snapshot(pair.receiverLibrary, pair.namespace)
    XCTAssertFalse(try publication(of: pair.first.id, in: storage).metadataAccepted)
    try await pair.receiver.sync()
    let remote = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(pair.first.metadataIdentity)
    )
    XCTAssertEqual(remote?.encryptedFields["fileName"], .string("c.txt"))
  }

  func testDownloadingADownloadedAttachmentKeepsItsUnsentRename() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await renameAttachment(ofSnip: pair.snipID, to: "renamed here.txt", in: pair.receiverLibrary)
    try await pair.downloads.clearDownloads()

    _ = try await pair.downloads.download(attachmentID: pair.first.id)

    let local = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(
      local.snips.first(where: { $0.id == pair.snipID })?.attachments.first?.fileName,
      "renamed here.txt"
    )
    let batch = try await pair.receiverStore.pendingChanges()
    XCTAssertTrue(plansMetadataSave(for: pair.first, in: batch))
  }

  func testFetchingThisDevicesOwnAcceptedRecordChangesNothing() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await editDownloadedAttachments(pair, keeping: [pair.second.id, pair.first.id])
    try await pair.receiver.sync()
    let before = try await snapshot(pair.receiverLibrary, pair.namespace)
    let beforeLocal = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    let beforeSnip = try XCTUnwrap(beforeLocal.snips.first(where: { $0.id == pair.snipID }))

    try await pair.receiver.fetchRemote()

    let after = try await snapshot(pair.receiverLibrary, pair.namespace)
    XCTAssertEqual(after.publications, before.publications)
    let afterLocal = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(afterLocal.snips.first(where: { $0.id == pair.snipID }), beforeSnip)
  }

  func testAReorderFromTheDeviceThatHoldsTheFilesReachesADownloadOnlyDevice() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await keepAttachments([pair.second.id, pair.first.id], ofSnip: pair.snipID, in: pair.senderLibrary)
    try await pair.sender.sync()

    try await pair.receiver.fetchRemote()

    let local = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(
      local.snips.first(where: { $0.id == pair.snipID })?.attachments.map(\.id),
      [pair.second.id, pair.first.id]
    )
    let batch = try await pair.receiverStore.pendingChanges()
    let attachmentIDs = [pair.first.metadataIdentity, pair.second.metadataIdentity]
      .map(CloudAttachmentRecordCodec.recordID)
    XCTAssertFalse(batch.operations.contains(where: { attachmentIDs.contains($0.id) }))
  }

  func testARemovalWinsOverAnEditFetchedBeforeItsDeleteIsSent() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let storage = try await snapshot(pair.receiverLibrary, pair.namespace)
    let oldPayload = try publication(of: pair.second.id, in: storage).metadata.payloadIdentity
    try await editDownloadedAttachments(pair, keeping: [pair.first.id])
    _ = try await pair.receiverStore.pendingChanges()
    try await keepAttachments([pair.second.id, pair.first.id], ofSnip: pair.snipID, in: pair.senderLibrary)
    try await pair.sender.sync()

    try await pair.receiver.fetchRemote()
    try await pair.receiver.sync()
    try await pair.receiver.sync()
    try await pair.sender.sync()
    try await pair.receiver.sendPending()

    let metadata = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(pair.second.metadataIdentity)
    )
    let payload = await pair.server.fullSnapshot(for: CloudAttachmentRecordCodec.recordID(oldPayload))
    XCTAssertNil(metadata)
    XCTAssertNil(payload)
    for library in [pair.senderLibrary, pair.receiverLibrary] {
      let local = try await library.checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(local.snips.first(where: { $0.id == pair.snipID })?.attachments.map(\.id), [pair.first.id])
      let settled = try await snapshot(library, pair.namespace)
      XCTAssertNil(settled.publications.first(where: { $0.metadata.attachmentID == pair.second.id }))
    }
    let settled = try await snapshot(pair.receiverLibrary, pair.namespace)
    XCTAssertEqual(settled.cleanups, [])
  }

  func testARemapAfterAnotherDeviceDeletedTheAttachmentRepublishesBytesThatDeviceCanOpen() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let before = try await snapshot(pair.receiverLibrary, pair.namespace)
    let oldPayload = try publication(of: pair.second.id, in: before).metadata.payloadIdentity
    try await editDownloadedAttachments(pair, keeping: [pair.first.id])
    _ = try await pair.receiverStore.pendingChanges()
    for _ in 0..<3 { try await pair.receiver.sync() }
    let deletedMetadata = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(pair.second.metadataIdentity)
    )
    let deletedPayload = await pair.server.fullSnapshot(for: CloudAttachmentRecordCodec.recordID(oldPayload))
    XCTAssertNil(deletedMetadata)
    XCTAssertNil(deletedPayload)
    try await keepAttachments([pair.second.id, pair.first.id], ofSnip: pair.snipID, in: pair.senderLibrary)

    try await pair.sender.sendPending()
    for _ in 0..<3 { try await pair.sender.sendPending() }
    try await pair.receiver.fetchRemote()

    let storage = try await snapshot(pair.senderLibrary, pair.namespace)
    let replacement = try XCTUnwrap(storage.publications.first(where: { $0.metadata.fileName == "second.txt" }))
    XCTAssertNotEqual(replacement.metadata.attachmentID, pair.second.id)
    XCTAssertNotEqual(replacement.metadata.payloadIdentity, oldPayload)
    let metadata = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(replacement.metadataIdentity)
    )
    let payload = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(replacement.metadata.payloadIdentity)
    )
    XCTAssertEqual(metadata?.encryptedFields["payloadRecordName"], .string(replacement.metadata.payloadIdentity.recordName))
    XCTAssertNotNil(payload)
    let local = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    XCTAssertTrue(try XCTUnwrap(local.snips.first(where: { $0.id == pair.snipID }))
      .attachments.contains(where: { $0.id == replacement.metadata.attachmentID }))
    do {
      let opened = try await pair.downloads.download(attachmentID: replacement.metadata.attachmentID)
      XCTAssertEqual(try Data(contentsOf: opened), pair.second.bytes)
    } catch {
      XCTFail("The remapped attachment must download its original bytes: \(error)")
    }
    XCTAssertEqual(storage.cleanups, [])
  }

  func testRestoringALocalAttachmentWhileItsDeleteIsInFlightRepublishesAFreshPayloadAndCleansTheOldOne() async throws {
    let held = try await makeHeldMetadataDelete()
    let client = held.client
    defer { try? FileManager.default.removeItem(at: client.root) }
    try await restoreSnip(held.snip, in: client.library)
    _ = try await client.store.pendingChanges()
    try await client.store.stage(.sent(held.sent), outbound: held.outbound)
    try await client.store.applyStaged(held.sent.id)
    try await client.transport.confirmApplied(held.sent.id)

    for _ in 0..<3 { try await client.sync.sync() }

    let storage = try await snapshot(client.library, client.namespace)
    let replacement = try XCTUnwrap(storage.publications.first)
    XCTAssertNotEqual(replacement.metadata.payloadIdentity, held.published.metadata.payloadIdentity)
    let metadata = await client.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(replacement.metadataIdentity)
    )
    let payload = await client.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(replacement.metadata.payloadIdentity)
    )
    let oldPayload = await client.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(held.published.metadata.payloadIdentity)
    )
    XCTAssertEqual(metadata?.encryptedFields["payloadRecordName"], .string(replacement.metadata.payloadIdentity.recordName))
    XCTAssertNotNil(payload)
    XCTAssertNil(oldPayload)
    XCTAssertEqual(storage.cleanups, [])
    let staged = try await client.store.stagedBatches()
    XCTAssertEqual(staged, [])
  }

  func testARemapOfAReplacedAttachmentOwesBothOldPayloads() async throws {
    let fixture = try await makePendingAttachmentFixture(names: ["replaced"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let initial = try await snapshot(fixture.library, fixture.namespace)
    let pending = try XCTUnwrap(initial.publications.first)
    let firstPayloadShadow = try payloadShadow(pending.metadata.payloadIdentity)
    let metadataRecord = try metadataShadow(pending.metadataIdentity)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [
        .payloadAccepted(attachmentID: pending.metadata.attachmentID, expectedRevision: pending.revision,
          shadowData: firstPayloadShadow.data, systemFields: firstPayloadShadow.systemFields),
        .metadataAccepted(attachmentID: pending.metadata.attachmentID, expectedRevision: pending.revision + 1,
          shadowData: metadataRecord.data, systemFields: metadataRecord.systemFields),
      ]
    )
    let localFile = try XCTUnwrap(pending.localSourceURL)
    try Data("replacement bytes".utf8).write(to: localFile)
    _ = try await fixture.store.pendingChanges()
    let changedStorage = try await snapshot(fixture.library, fixture.namespace)
    let changed = try XCTUnwrap(changedStorage.publications.first)
    let secondPayloadShadow = try payloadShadow(changed.metadata.payloadIdentity)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.payloadAccepted(attachmentID: changed.metadata.attachmentID, expectedRevision: changed.revision,
        shadowData: secondPayloadShadow.data, systemFields: secondPayloadShadow.systemFields)]
    )
    let acceptedStorage = try await snapshot(fixture.library, fixture.namespace)
    let accepted = try XCTUnwrap(acceptedStorage.publications.first)
    let replacementID = UUID()
    let replacementMetadata = CloudTextStorageIdentity(zoneName: "data", ownerName: "owner",
      recordName: "a-\(replacementID.uuidString.lowercased())")

    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.metadataUnknown(attachmentID: accepted.metadata.attachmentID, expectedRevision: accepted.revision,
        replacementAttachmentID: replacementID, replacementMetadataIdentity: replacementMetadata)]
    )

    let remapped = try await snapshot(fixture.library, fixture.namespace)
    let replacement = try publication(of: replacementID, in: remapped)
    XCTAssertFalse(replacement.payloadAccepted)
    XCTAssertNotEqual(replacement.metadata.payloadIdentity, pending.metadata.payloadIdentity)
    XCTAssertNotEqual(replacement.metadata.payloadIdentity, accepted.metadata.payloadIdentity)
    XCTAssertNil(replacement.priorPayloadIdentity)
    XCTAssertEqual(Set(remapped.cleanups.map(\.identity)), [pending.metadata.payloadIdentity, accepted.metadata.payloadIdentity])
    for (identity, shadow) in [(pending.metadata.payloadIdentity, firstPayloadShadow),
      (accepted.metadata.payloadIdentity, secondPayloadShadow)]
    {
      let cleanup = try XCTUnwrap(remapped.cleanups.first(where: { $0.identity == identity }))
      XCTAssertEqual(cleanup.shadowData, shadow.data)
      XCTAssertEqual(cleanup.blockedByAttachmentID, replacementID)
    }
    let upload = try await fixture.store.pendingChanges()
    XCTAssertTrue(upload.operations.contains(where: { $0.id == CloudAttachmentRecordCodec.recordID(replacement.metadata.payloadIdentity) }))
    XCTAssertFalse(upload.operations.contains(where: { $0.id == CloudAttachmentRecordCodec.recordID(replacementMetadata) }))
    let oldPayloadIDs = [pending.metadata.payloadIdentity, accepted.metadata.payloadIdentity]
      .map(CloudAttachmentRecordCodec.recordID)
    XCTAssertFalse(upload.operations.contains(where: { oldPayloadIDs.contains($0.id) }))
    let readyStorage = try await snapshot(fixture.library, fixture.namespace)
    let ready = try publication(of: replacementID, in: readyStorage)
    let freshShadow = try payloadShadow(ready.metadata.payloadIdentity)
    let freshMetadataShadow = try metadataShadow(replacementMetadata)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [
        .payloadAccepted(attachmentID: replacementID, expectedRevision: ready.revision,
          shadowData: freshShadow.data, systemFields: freshShadow.systemFields),
        .metadataAccepted(attachmentID: replacementID, expectedRevision: ready.revision + 1,
          shadowData: freshMetadataShadow.data, systemFields: freshMetadataShadow.systemFields),
      ]
    )
    let released = try await fixture.store.pendingChanges()
    for id in oldPayloadIDs {
      XCTAssertTrue(released.operations.contains(where: { operation in
        if case .delete(let deletedID, _) = operation { deletedID == id } else { false }
      }))
    }
  }

  func testARemappedAttachmentWhoseFileChangedUploadsTheNewBytes() async throws {
    let setup = try await makeRemovedPublishedAttachmentFixture()
    let fixture = setup.fixture
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let remaining = setup.remaining
    let replacementID = UUID()
    let replacementMetadata = CloudTextStorageIdentity(zoneName: "data", ownerName: "owner",
      recordName: "a-\(replacementID.uuidString.lowercased())")
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.metadataUnknown(attachmentID: remaining.metadata.attachmentID, expectedRevision: remaining.revision,
        replacementAttachmentID: replacementID, replacementMetadataIdentity: replacementMetadata)]
    )
    let bytes = Data("changed after the remap".utf8)
    try bytes.write(to: XCTUnwrap(remaining.localSourceURL))

    let batch = try await fixture.store.pendingChanges()

    let storage = try await snapshot(fixture.library, fixture.namespace)
    let replacement = try publication(of: replacementID, in: storage)
    XCTAssertNotEqual(replacement.metadata.payloadIdentity, remaining.metadata.payloadIdentity)
    XCTAssertEqual(replacement.metadata.sha256, Data(SHA256.hash(data: bytes)))
    let payloadID = CloudAttachmentRecordCodec.recordID(replacement.metadata.payloadIdentity)
    XCTAssertTrue(batch.operations.contains(where: { operation in
      if case .save(let draft) = operation { draft.id == payloadID } else { false }
    }))
    XCTAssertFalse(batch.operations.contains(where: { $0.id == CloudAttachmentRecordCodec.recordID(replacementMetadata) }))
  }

  func testADuplicateOldPayloadDeleteFromTheRemapAndTheDeleterSettlesInEitherOrder() async throws {
    for remappingDeviceDeletesFirst in [true, false] {
      let pair = try await makeDownloadedAttachmentPair()
      defer { try? FileManager.default.removeItem(at: pair.root) }
      let initial = try await snapshot(pair.receiverLibrary, pair.namespace)
      let oldPayload = try publication(of: pair.second.id, in: initial).metadata.payloadIdentity
      let oldPayloadID = CloudAttachmentRecordCodec.recordID(oldPayload)
      try await editDownloadedAttachments(pair, keeping: [pair.first.id])
      _ = try await pair.receiverStore.pendingChanges()
      try await pair.receiver.sync()
      // D2 only fetched metadata, so its first cleanup send learns the payload's shadow.
      try await pair.receiver.sendPending()
      let afterConflict = try await snapshot(pair.receiverLibrary, pair.namespace)
      let deleterCleanup = try XCTUnwrap(afterConflict.cleanups.first(where: { $0.identity == oldPayload }))
      XCTAssertNotNil(deleterCleanup.shadowData)
      XCTAssertNil(deleterCleanup.lastFailure)
      try await keepAttachments([pair.second.id, pair.first.id], ofSnip: pair.snipID, in: pair.senderLibrary)
      try await pair.sender.sendPending()
      let remapped = try await snapshot(pair.senderLibrary, pair.namespace)
      let replacement = try XCTUnwrap(remapped.publications.first(where: { $0.metadata.fileName == "second.txt" }))
      for library in [pair.senderLibrary, pair.receiverLibrary] {
        let storage = try await snapshot(library, pair.namespace)
        XCTAssertNotNil(storage.cleanups.first(where: { $0.identity == oldPayload }))
      }
      if !remappingDeviceDeletesFirst {
        let firstDelete = try await pair.receiver.sendPending()
        XCTAssertNil(firstDelete.issue)
      }
      // Upload the replacement payload, then publish its metadata before D1's cleanup.
      try await pair.sender.sendPending()
      try await pair.sender.sendPending()
      if remappingDeviceDeletesFirst {
        let firstDelete = try await pair.sender.sendPending()
        XCTAssertNil(firstDelete.issue)
      }
      let secondStore = remappingDeviceDeletesFirst ? pair.receiverStore : pair.senderStore
      let secondLibrary = remappingDeviceDeletesFirst ? pair.receiverLibrary : pair.senderLibrary
      let secondTransport: any CloudRecordTransport = if remappingDeviceDeletesFirst {
        pair.assetFetches
      } else {
        pair.senderTransport
      }
      let beforeSecondDelete = try await snapshot(secondLibrary, pair.namespace)
      let cleanup = try XCTUnwrap(beforeSecondDelete.cleanups.first(where: { $0.identity == oldPayload }))
      XCTAssertNil(cleanup.lastFailure)
      let outbound = try await secondStore.pendingChanges()
      XCTAssertTrue(outbound.operations.contains(where: { operation in
        if case .delete(let id, _) = operation { id == oldPayloadID } else { false }
      }))
      let secondDelete = try await secondTransport.send(outbound)
      XCTAssertTrue(secondDelete.items.contains(.unknownItem(oldPayloadID)))
      try await secondStore.stage(.sent(secondDelete), outbound: outbound)
      let staged = try await secondStore.stagedBatches()
      let acceptance = try XCTUnwrap(staged.first(where: { $0.batchID == secondDelete.id }))
      XCTAssertTrue(acceptance.attachmentTransitions.contains(.cleanupAccepted(
        identity: oldPayload,
        expectedRevision: cleanup.revision
      )))
      try await secondStore.applyStaged(secondDelete.id)
      try await secondTransport.confirmApplied(secondDelete.id)
      if case .issue(let issue) = try await secondStore.syncStatus() {
        XCTFail("The second delete must settle without a sync issue: \(issue)")
      }

      for library in [pair.senderLibrary, pair.receiverLibrary] {
        let storage = try await snapshot(library, pair.namespace)
        XCTAssertEqual(storage.cleanups, [], "Both deletes must settle without failure or quarantine.")
        XCTAssertEqual(storage.publications.compactMap(\.lastFailure), [])
      }
      let senderPlan = try await pair.senderStore.pendingChanges()
      let receiverPlan = try await pair.receiverStore.pendingChanges()
      for plan in [senderPlan, receiverPlan] {
        XCTAssertFalse(plan.operations.contains(where: { $0.id == oldPayloadID }), "The deleted payload must never retry.")
      }
      let oldRecord = await pair.server.fullSnapshot(for: oldPayloadID)
      let metadata = await pair.server.fullSnapshot(for: CloudAttachmentRecordCodec.recordID(replacement.metadataIdentity))
      let payload = await pair.server.fullSnapshot(for: CloudAttachmentRecordCodec.recordID(replacement.metadata.payloadIdentity))
      XCTAssertNil(oldRecord)
      XCTAssertEqual(metadata?.encryptedFields["payloadRecordName"], .string(replacement.metadata.payloadIdentity.recordName))
      XCTAssertNotNil(payload)
      try await pair.receiver.fetchRemote()
      do {
        let opened = try await pair.downloads.prepare(attachmentID: replacement.metadata.attachmentID, for: .open)
        XCTAssertEqual(try Data(contentsOf: opened), pair.second.bytes)
      } catch {
        XCTFail("Either delete order must leave the replacement openable: \(error)")
      }
    }
  }

  // 7a: a device that only downloaded its attachments publishes a reorder like any other
  // metadata edit. Their payloads stay accepted, so the bytes stay recoverable from CloudKit.
  func testReorderingDownloadedAttachmentsPublishesTheOrderAndKeepsThemOpenable() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let first = pair.first
    let second = pair.second
    try await editDownloadedAttachments(pair, keeping: [second.id, first.id])

    let batch = try await pair.receiverStore.pendingChanges()

    let pending = try await snapshot(pair.receiverLibrary, pair.namespace)
    XCTAssertEqual(pending.publications.compactMap(\.lastFailure), [])
    XCTAssertFalse(pending.publications.contains(where: \.metadataAccepted))
    for attachment in [first, second] {
      XCTAssertTrue(
        plansMetadataSave(for: attachment, in: batch),
        "\(attachment.fileName) must publish its new position."
      )
    }
    let states = try await pair.downloads.transferStates()
    XCTAssertEqual(
      states,
      [first.id: .available, second.id: .available],
      "A pending reorder must not hide payloads CloudKit holds."
    )
    let fetchesBeforeOpen = await pair.assetFetches.count
    for attachment in [first, second] {
      let opened = try await pair.downloads.prepare(attachmentID: attachment.id, for: .open)
      XCTAssertEqual(opened, attachment.cachedURL)
      XCTAssertEqual(try Data(contentsOf: opened), attachment.bytes)
    }
    let fetchesAfterOpen = await pair.assetFetches.count
    XCTAssertEqual(fetchesAfterOpen, fetchesBeforeOpen, "Cached bytes must open without a fetch.")

    try await pair.receiver.sync()

    let synced = try await snapshot(pair.receiverLibrary, pair.namespace)
    XCTAssertTrue(synced.publications.allSatisfy { $0.metadataAccepted && $0.lastFailure == nil })
    try await pair.sender.fetchRemote()
    // Client 1 adopts the fetched order while keeping its local files.
    let arrived = try await snapshot(pair.senderLibrary, pair.namespace)
    let arrivedSecond = try publication(of: second.id, in: arrived)
    let arrivedFirst = try publication(of: first.id, in: arrived)
    XCTAssertEqual(arrivedSecond.metadata.position, 0)
    XCTAssertEqual(arrivedFirst.metadata.position, 1)
    XCTAssertTrue(arrived.publications.allSatisfy { $0.metadataAccepted && $0.lastFailure == nil })
  }

  // 7a through a removal: removing the first of two downloaded attachments moves the second to
  // position 0, a metadata edit of an attachment this device only downloaded.
  func testRemovingTheFirstDownloadedAttachmentSyncsTheMoveAndKeepsTheOtherOpenable() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let removed = pair.first
    let moved = pair.second
    try await editDownloadedAttachments(pair, keeping: [moved.id])

    let batch = try await pair.receiverStore.pendingChanges()

    let pending = try await snapshot(pair.receiverLibrary, pair.namespace)
    let pendingMove = try publication(of: moved.id, in: pending)
    XCTAssertNil(pendingMove.lastFailure)
    XCTAssertEqual(pendingMove.metadata.position, 0)
    XCTAssertFalse(pendingMove.metadataAccepted)
    XCTAssertTrue(plansMetadataSave(for: moved, in: batch), "The move must publish.")
    XCTAssertTrue(batch.operations.contains(where: { operation in
      guard case .delete = operation else { return false }
      return operation.id == CloudAttachmentRecordCodec.recordID(removed.metadataIdentity)
    }))
    let states = try await pair.downloads.transferStates()
    XCTAssertEqual(states[moved.id], .available, "A pending move must not hide the payload.")
    let fetchesBeforeOpen = await pair.assetFetches.count
    let opened = try await pair.downloads.prepare(attachmentID: moved.id, for: .open)
    XCTAssertEqual(opened, moved.cachedURL)
    XCTAssertEqual(try Data(contentsOf: opened), moved.bytes)
    let fetchesAfterOpen = await pair.assetFetches.count
    XCTAssertEqual(fetchesAfterOpen, fetchesBeforeOpen, "Cached bytes must open without a fetch.")

    try await pair.downloads.clearDownloads()
    let downloaded = try await pair.downloads.download(attachmentID: moved.id)

    XCTAssertEqual(try Data(contentsOf: downloaded), moved.bytes)
    let fetchesAfterDownload = await pair.assetFetches.count
    XCTAssertEqual(fetchesAfterDownload, fetchesAfterOpen + 1)
    let stillPending = try await snapshot(pair.receiverLibrary, pair.namespace)
    let stillPendingMove = try publication(of: moved.id, in: stillPending)
    XCTAssertFalse(stillPendingMove.metadataAccepted, "The move must still be pending.")

    try await pair.receiver.sync()

    let synced = try await snapshot(pair.receiverLibrary, pair.namespace)
    let syncedMove = try publication(of: moved.id, in: synced)
    XCTAssertTrue(syncedMove.metadataAccepted)
    XCTAssertNil(syncedMove.lastFailure)
    try await pair.sender.fetchRemote()
    let arrived = try await snapshot(pair.senderLibrary, pair.namespace)
    let arrivedMove = try publication(of: moved.id, in: arrived)
    XCTAssertEqual(arrivedMove.metadata.position, 0)
    XCTAssertNil(arrived.publications.first(where: { $0.metadata.attachmentID == removed.id }))
    let senderLocal = try await pair.senderLibrary.checkedSnapshot(sortedBy: .manual)
    let senderSnip = try XCTUnwrap(senderLocal.snips.first(where: { $0.id == pair.snipID }))
    XCTAssertEqual(senderSnip.attachments.map(\.id), [moved.id])
  }

  // 7a through Keep Local Copy: the durable copy recovers evicted bytes from the accepted
  // payload while a metadata edit is still pending.
  func testKeepingALocalCopyRecoversEvictedDownloadsWhileAMetadataEditIsPending() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await editDownloadedAttachments(pair, keeping: [pair.second.id, pair.first.id])
    _ = try await pair.receiverStore.pendingChanges()
    let pending = try await snapshot(pair.receiverLibrary, pair.namespace)
    XCTAssertFalse(pending.publications.contains(where: \.metadataAccepted))
    try await pair.downloads.clearDownloads()
    let fetchesBefore = await pair.assetFetches.count

    let recoveredMissingBytes = try await pair.downloads.preserveAllAttachmentsForLocalCopy()

    XCTAssertTrue(recoveredMissingBytes)
    let fetchesAfter = await pair.assetFetches.count
    XCTAssertEqual(fetchesAfter, fetchesBefore + 2)
    let local = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == pair.snipID }))
    XCTAssertEqual(snip.attachments.map(\.id), [pair.second.id, pair.first.id])
    for attachment in [pair.first, pair.second] {
      let kept = try XCTUnwrap(snip.attachments.first(where: { $0.id == attachment.id }))
      XCTAssertFalse(kept.relativePath.hasPrefix("CloudDownloads/"), attachment.fileName)
      let keptURL = try XCTUnwrap(local.attachmentURLs[attachment.id])
      XCTAssertEqual(try Data(contentsOf: keptURL), attachment.bytes)
    }
  }

  // 7a through Keep Local Copy with corrupt downloads: the durable copy rejects the cached
  // bytes and recovers the originals from the accepted payload while a metadata edit is pending.
  func testKeepingALocalCopyReplacesCorruptDownloadsWhileAMetadataEditIsPending() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await editDownloadedAttachments(pair, keeping: [pair.second.id, pair.first.id])
    _ = try await pair.receiverStore.pendingChanges()
    let pending = try await snapshot(pair.receiverLibrary, pair.namespace)
    XCTAssertFalse(
      pending.publications.contains(where: \.metadataAccepted),
      "The edit must still wait to sync."
    )
    for attachment in [pair.first, pair.second] {
      try Data(repeating: 0xA5, count: attachment.bytes.count).write(to: attachment.cachedURL)
    }
    let fetchesBefore = await pair.assetFetches.count

    let recoveredMissingBytes = try await pair.downloads.preserveAllAttachmentsForLocalCopy()

    XCTAssertTrue(recoveredMissingBytes, "Corrupt downloads must be recovered from CloudKit.")
    let fetchesAfter = await pair.assetFetches.count
    XCTAssertEqual(fetchesAfter, fetchesBefore + 2, "Each corrupt download must be fetched again.")
    let local = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == pair.snipID }))
    for attachment in [pair.first, pair.second] {
      let kept = try XCTUnwrap(
        snip.attachments.first(where: { $0.id == attachment.id }),
        attachment.fileName
      )
      XCTAssertFalse(
        kept.relativePath.hasPrefix("CloudDownloads/"),
        "\(attachment.fileName) must move to durable storage."
      )
      let keptURL = try XCTUnwrap(local.attachmentURLs[attachment.id], attachment.fileName)
      XCTAssertEqual(
        try Data(contentsOf: keptURL),
        attachment.bytes,
        "\(attachment.fileName) must keep the original server bytes."
      )
    }
  }

  // 7a through a restart: a fresh coordinator sweeps the cache on its first lookup. A pending
  // metadata edit must not make that sweep discard downloads whose payloads CloudKit holds.
  func testReopeningDuringAPendingEditKeepsTheDownloadsAndOpensThemWithoutFetching() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await editDownloadedAttachments(pair, keeping: [pair.second.id, pair.first.id])
    _ = try await pair.receiverStore.pendingChanges()
    let reopened = try SwiftDataSnipLibrary(
      storeURL: pair.root.appendingPathComponent("receiver.store")
    )
    let pending = try await snapshot(reopened, pair.namespace)
    XCTAssertFalse(
      pending.publications.contains(where: \.metadataAccepted),
      "The edit must still wait to sync after the reopen."
    )
    let fetches = AssetFetchCountingTransport(base: pair.assetFetches)
    let downloads = CloudAttachmentTransferCoordinator(
      library: reopened,
      namespace: pair.namespace,
      payloadZone: CloudZoneID(name: "payload", ownerName: "owner"),
      transport: fetches,
      maximumCacheBytes: 1_024
    )

    for attachment in [pair.first, pair.second] {
      let opened = try await downloads.prepare(attachmentID: attachment.id, for: .open)
      XCTAssertEqual(
        opened.standardizedFileURL,
        attachment.cachedURL.standardizedFileURL,
        "\(attachment.fileName) must open from the download made before the reopen."
      )
      XCTAssertEqual(
        try Data(contentsOf: opened),
        attachment.bytes,
        "\(attachment.fileName) must open with its original bytes."
      )
    }

    let fetchCount = await fetches.count
    XCTAssertEqual(fetchCount, 0, "Verified downloads must open without a fetch.")
    let afterOpen = try await snapshot(reopened, pair.namespace)
    XCTAssertEqual(
      Set(afterOpen.cacheEntries.map(\.attachmentID)),
      [pair.first.id, pair.second.id],
      "The startup sweep must keep both downloads."
    )
    XCTAssertFalse(
      afterOpen.publications.contains(where: \.metadataAccepted),
      "The downloads must open before the metadata syncs."
    )
  }

  // SM32-F1-D1: client 1 removes an attachment, and its metadata delete and payload cleanup
  // land. Client 2, which only downloaded it, reorders it before fetching that delete, so its
  // metadata save comes back unknown. Client 2 has no bytes to republish, so the delete wins.
  func testUnknownMetadataSaveOnADownloadOnlyDeviceAppliesTheRemoteDelete() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let kept = pair.first
    let deleted = pair.second
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let received = try await snapshot(pair.receiverLibrary, pair.namespace)
    let deletedPayload = try publication(of: deleted.id, in: received).metadata.payloadIdentity
    let deletedPayloadID = CloudAttachmentRecordCodec.recordID(deletedPayload)
    let senderLocal = try await pair.senderLibrary.checkedSnapshot(sortedBy: .manual)
    let senderSnip = try XCTUnwrap(senderLocal.snips.first(where: { $0.id == pair.snipID }))
    _ = try await pair.senderLibrary.perform(
      .editAttachments(
        snipID: senderSnip.id,
        content: senderSnip.content,
        edits: [.existing(attachmentID: kept.id)],
        expectedUpdatedAt: senderSnip.updatedAt,
        now: Date(timeIntervalSince1970: 3)
      ),
      sortedBy: .manual
    )
    for _ in 0..<3 { try await pair.sender.sync() }
    let deletedMetadataRecord = await pair.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(deleted.metadataIdentity)
    )
    XCTAssertNil(deletedMetadataRecord, "Client 1's metadata delete must be accepted.")
    let deletedPayloadRecord = await pair.server.fullSnapshot(for: deletedPayloadID)
    XCTAssertNil(deletedPayloadRecord, "Client 1's payload cleanup must run.")

    try await editDownloadedAttachments(pair, keeping: [deleted.id, kept.id])
    try await pair.receiver.sendPending()

    let local = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == pair.snipID }))
    XCTAssertEqual(
      snip.attachments.map(\.id),
      [kept.id],
      "Client 2 must apply the remote delete instead of keeping the reordered attachment."
    )
    let storage = try await snapshot(pair.receiverLibrary, pair.namespace)
    XCTAssertEqual(
      storage.publications.map(\.metadata.attachmentID),
      [kept.id],
      "Client 2 must not republish the deleted attachment under any ID."
    )
    XCTAssertFalse(
      storage.cleanups.contains(where: { $0.identity == deletedPayload }),
      "Client 1 owns the deleted payload's cleanup."
    )
    XCTAssertFalse(
      storage.cacheEntries.contains(where: { $0.attachmentID == deleted.id }),
      "Client 2 must drop the deleted attachment's download."
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: deleted.cachedURL.path),
      "Client 2 must remove the deleted attachment's cached file."
    )

    try await pair.receiver.sendPending()

    let metadataRecordCount = await pair.server.storedRecordTypes(in: dataZone)
      .filter { $0 == CloudAttachmentRecordCodec.metadataRecordType }
      .count
    XCTAssertEqual(metadataRecordCount, 1, "Client 2 must save no new metadata record.")
    let payloadRecordAfterSend = await pair.server.fullSnapshot(for: deletedPayloadID)
    XCTAssertNil(payloadRecordAfterSend, "Nothing may bring back the deleted payload.")

    try await pair.receiver.fetchRemote()
    try await pair.sender.fetchRemote()

    let clients = [("client 1", pair.senderLibrary), ("client 2", pair.receiverLibrary)]
    for (client, library) in clients {
      let fetched = try await library.checkedSnapshot(sortedBy: .manual)
      let fetchedSnip = try XCTUnwrap(fetched.snips.first(where: { $0.id == pair.snipID }), client)
      XCTAssertEqual(
        fetchedSnip.attachments.map(\.id),
        [kept.id],
        "The deleted attachment must not reappear on \(client)."
      )
      let fetchedStorage = try await snapshot(library, pair.namespace)
      XCTAssertFalse(
        fetchedStorage.publications.contains { $0.metadata.payloadIdentity == deletedPayload },
        "Nothing on \(client) may reference the deleted payload."
      )
    }
  }

  // MARK: Acknowledgements after local edits (SM33)

  // 5b: removing the first of two attachments moves the second. The second is removed before
  // that move syncs, so CloudKit still holds its published metadata.
  func testRemovingAnAttachmentWhosePositionSaveIsPendingDeletesItsMetadataBeforeItsPayload() async throws {
    let setup = try await makeRemovedPublishedAttachmentFixture()
    let fixture = setup.fixture
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let moved = setup.remaining
    let metadataBase = try CloudRecordShadow(data: XCTUnwrap(
      moved.metadataShadowData,
      "The moved attachment must keep its published metadata shadow."
    ))
    let payloadBase = try CloudRecordShadow(data: XCTUnwrap(
      moved.payloadShadowData,
      "The moved attachment must keep its accepted payload shadow."
    ))
    let payloadID = CloudAttachmentRecordCodec.recordID(moved.metadata.payloadIdentity)
    try await keepAttachments([], ofSnip: moved.metadata.snipID, in: fixture.library)

    let plan = try await fixture.store.pendingChanges()

    XCTAssertTrue(
      plan.operations.contains(.delete(
        CloudAttachmentRecordCodec.recordID(moved.metadataIdentity),
        base: metadataBase
      )),
      "CloudKit still holds the moved attachment's metadata, so removing it must delete that metadata."
    )
    XCTAssertFalse(
      plan.operations.contains(where: { $0.id == payloadID }),
      "The payload must wait until CloudKit accepts the metadata delete."
    )
    let removed = try await snapshot(fixture.library, fixture.namespace)
    let removedMoved = try XCTUnwrap(
      removed.publications.first(where: {
        $0.metadata.attachmentID == moved.metadata.attachmentID
      }),
      "The removed attachment must keep its publication until its metadata delete is accepted."
    )
    XCTAssertFalse(removedMoved.isLocallyPresent, "The publication must record the removal.")
    XCTAssertFalse(
      removed.cleanups.contains(where: { $0.identity == moved.metadata.payloadIdentity }),
      "Nothing may owe the payload a cleanup while published metadata names it."
    )

    let reopenedLibrary = try SwiftDataSnipLibrary(
      storeURL: fixture.root.appendingPathComponent("store")
    )
    let reopened = try await snapshot(reopenedLibrary, fixture.namespace)
    XCTAssertEqual(reopened, removed, "The removed publication must survive a reopen unchanged.")

    try await reopenedLibrary.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.metadataDeleteAccepted(
        attachmentID: moved.metadata.attachmentID,
        expectedRevision: removedMoved.revision
      )]
    )

    let deleted = try await snapshot(reopenedLibrary, fixture.namespace)
    XCTAssertFalse(
      deleted.publications.contains(where: {
        $0.metadata.attachmentID == moved.metadata.attachmentID
      }),
      "An accepted metadata delete must retire the publication."
    )
    XCTAssertEqual(
      deleted.cleanups.filter { $0.identity == moved.metadata.payloadIdentity }.count,
      1,
      "The accepted delete must owe exactly one cleanup for this payload."
    )
    let cleanup = try XCTUnwrap(
      deleted.cleanups.first(where: { $0.identity == moved.metadata.payloadIdentity }),
      "An accepted metadata delete must owe the payload its cleanup."
    )
    XCTAssertEqual(
      cleanup.shadowData,
      moved.payloadShadowData,
      "The cleanup must delete from the accepted payload shadow."
    )
    XCTAssertNil(cleanup.blockedByAttachmentID, "No replacement waits at the removed location.")
    let reopenedStore = CloudFullSyncPersistence(
      library: reopenedLibrary,
      namespace: fixture.namespace,
      dataZone: CloudZoneID(name: "data", ownerName: "owner"),
      payloadZone: CloudZoneID(name: "payload", ownerName: "owner")
    )
    let next = try await reopenedStore.pendingChanges()
    XCTAssertTrue(
      next.operations.contains(.delete(payloadID, base: payloadBase)),
      "Once the metadata is gone, the next plan must delete the payload."
    )
  }

  // 5b across devices: client 1 removes A, plans the move of B offline, then removes B.
  func testRemovingBothAttachmentsBeforeTheMoveSyncsLeavesNoAttachmentOnTheOtherDevice() async throws {
    let client = try await makeAttachmentClient(fileNames: ["first", "second"])
    defer { try? FileManager.default.removeItem(at: client.root) }
    // The first sync accepts the payloads; the second publishes the metadata that names them.
    try await client.sync.sync()
    try await client.sync.sync()
    // Consume our published metadata so a later fetch cannot mask the removal's pending phase.
    try await client.sync.fetchRemote()
    let published = try await snapshot(client.library, client.namespace)
    XCTAssertEqual(published.publications.count, 2, "Client 1 must publish both attachments.")
    XCTAssertTrue(
      published.publications.allSatisfy(\.metadataAccepted),
      "Client 1 must publish both attachments' metadata."
    )
    let ordered = published.publications.sorted { $0.metadata.position < $1.metadata.position }
    let first = try XCTUnwrap(ordered.first, "Client 1 must publish the first attachment.")
    let second = try XCTUnwrap(ordered.last, "Client 1 must publish the second attachment.")
    let other = try attachmentClient(
      root: client.root,
      storeURL: client.root.appendingPathComponent("other.store"),
      namespace: client.namespace,
      server: client.server,
      snipID: client.snipID
    )
    try await other.sync.fetchRemote()
    let received = try await other.library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(
      received.snips.first(where: { $0.id == client.snipID })?.attachments.count,
      2,
      "Client 2 must receive both attachments."
    )

    try await keepAttachments([second.metadata.attachmentID], ofSnip: client.snipID, in: client.library)
    _ = try await client.store.pendingChanges()
    try await keepAttachments([], ofSnip: client.snipID, in: client.library)
    for _ in 0..<3 { try await client.sync.sync() }
    try await other.sync.fetchRemote()

    for publication in [first, second] {
      let metadataRecord = await client.server.fullSnapshot(
        for: CloudAttachmentRecordCodec.recordID(publication.metadataIdentity)
      )
      XCTAssertNil(metadataRecord, "\(publication.metadata.fileName)'s metadata must leave CloudKit.")
      let payloadRecord = await client.server.fullSnapshot(
        for: CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity)
      )
      XCTAssertNil(payloadRecord, "\(publication.metadata.fileName)'s payload must leave CloudKit.")
    }
    let otherLocal = try await other.library.checkedSnapshot(sortedBy: .manual)
    let otherSnip = try XCTUnwrap(
      otherLocal.snips.first(where: { $0.id == client.snipID }),
      "Client 2 must keep the snip."
    )
    XCTAssertEqual(otherSnip.attachments, [], "Client 2 must drop both attachments.")
    let otherStorage = try await snapshot(other.library, other.namespace)
    XCTAssertEqual(otherStorage.publications, [], "Client 2 must keep no publication.")
  }

  // 4a: the user restores an attachment with a local file while its metadata delete is in
  // flight. The delete lands, then its result comes back.
  func testRestoringAnAttachmentWhileItsDeleteIsInFlightKeepsSyncing() async throws {
    let held = try await makeHeldMetadataDelete()
    let client = held.client
    defer { try? FileManager.default.removeItem(at: client.root) }
    try await restoreSnip(held.snip, in: client.library)
    _ = try await client.store.pendingChanges()

    try await client.store.stage(.sent(held.sent), outbound: held.outbound)
    do {
      try await client.store.applyStaged(held.sent.id)
    } catch {
      return XCTFail("The delete's result must apply to the restored attachment, not throw \(error).")
    }
    try await client.transport.confirmApplied(held.sent.id)

    let text = "edited after the restore"
    try await editText(ofSnip: client.snipID, to: text, in: client.library)
    try await client.sync.sync()
    try await client.sync.sync()
    try await assertRestoreRepublished(held, in: client, text: text)
  }

  // 4b: the same restore on a device that only downloaded the attachment. It cannot republish
  // without the bytes, so the delete wins as soon as its result comes back.
  func testRestoringADownloadedAttachmentWhileItsDeleteIsInFlightSettlesOnTheDelete() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let kept = pair.first
    let restored = pair.second
    let beforeRemoval = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(
      beforeRemoval.snips.first(where: { $0.id == pair.snipID }),
      "Client 2 must hold the snip."
    )
    try await editDownloadedAttachments(pair, keeping: [kept.id])
    let outbound = try await pair.receiverStore.pendingChanges()
    let metadataID = CloudAttachmentRecordCodec.recordID(restored.metadataIdentity)
    XCTAssertTrue(
      outbound.operations.contains(where: { operation in
        if case .delete(let id, _) = operation { id == metadataID } else { false }
      }),
      "Removing the attachment must plan its metadata delete."
    )
    let sent = try await pair.assetFetches.send(outbound)
    let deletedRecord = await pair.server.fullSnapshot(for: metadataID)
    XCTAssertNil(deletedRecord, "CloudKit must apply the delete before its result comes back.")
    try await restoreSnip(snip, in: pair.receiverLibrary)
    _ = try await pair.receiverStore.pendingChanges()
    let restoredStorage = try await snapshot(pair.receiverLibrary, pair.namespace)
    let restoredPublication = try publication(of: restored.id, in: restoredStorage)
    XCTAssertTrue(
      restoredPublication.isLocallyPresent && restoredPublication.metadataAccepted,
      "The restore must bring back the published attachment with nothing to send."
    )

    try await pair.receiverStore.stage(.sent(sent), outbound: outbound)
    try await pair.receiverStore.applyStaged(sent.id)
    try await pair.assetFetches.confirmApplied(sent.id)

    let settled = try await snapshot(pair.receiverLibrary, pair.namespace)
    XCTAssertFalse(
      settled.publications.contains(where: { $0.metadata.attachmentID == restored.id }),
      "CloudKit applied the delete and this device holds no bytes to republish, so the delete must win now."
    )
    let local = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(
      local.snips.first(where: { $0.id == pair.snipID })?.attachments.map(\.id),
      [kept.id],
      "The snip must drop the attachment CloudKit no longer has."
    )

    try await pair.receiver.fetchRemote()

    let fetched = try await snapshot(pair.receiverLibrary, pair.namespace)
    XCTAssertEqual(
      fetched.publications,
      settled.publications,
      "Fetching this device's own delete must change nothing."
    )
    let fetchedLocal = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(
      fetchedLocal.snips.first(where: { $0.id == pair.snipID })?.attachments.map(\.id),
      [kept.id],
      "Fetching this device's own delete must not change the snip."
    )
  }

  // SM33 D7 (Adv-F2): a download-only device's delete conflicts with another device's rename,
  // and the user undoes the removal before the retry. The restored row keeps the name the device
  // last showed while its shadow holds the rename. The next remote change must keep the rename.
  func testUndoingARemovalWhoseDeleteConflictedKeepsTheOtherDevicesRename() async throws {
    let clients = try await makeAttachmentEditClients()
    let holder = clients.holder
    let downloaded = clients.downloaded
    defer { try? FileManager.default.removeItem(at: holder.root) }
    let a = AttachmentMatrixMember.a.id
    let b = AttachmentMatrixMember.b.id
    let c = AttachmentMatrixMember.c.id
    let beforeRemoval = try await downloaded.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(beforeRemoval.snips.first(where: { $0.id == downloaded.snipID }))
    try await keepAttachments([a, b], ofSnip: downloaded.snipID, in: downloaded.library)
    try await renameAttachment(ofSnip: holder.snipID, attachmentID: c, to: "remote-C.txt", in: holder.library)
    try await holder.sync.sync()

    try await downloaded.sync.sendPending()

    let conflictedStorage = try await snapshot(downloaded.library, downloaded.namespace)
    let conflicted = try publication(of: c, in: conflictedStorage)
    XCTAssertFalse(conflicted.isLocallyPresent, "The removal must wait for its delete to retry.")
    XCTAssertTrue(conflicted.metadataAccepted, "The delete conflict must adopt iCloud's record as its base.")
    try await restoreSnip(snip, in: downloaded.library)
    _ = try await downloaded.store.pendingChanges()
    let restoredStorage = try await snapshot(downloaded.library, downloaded.namespace)
    let restored = try publication(of: c, in: restoredStorage)
    XCTAssertTrue(restored.isLocallyPresent && restored.metadataAccepted, "The undo must bring C back with nothing to send.")
    XCTAssertEqual(restored.metadata.fileName, "C.txt", "The restored row must keep the name this device last showed.")
    let shadowName = try await shadowMetadata(of: c, in: downloaded)?.fileName
    XCTAssertEqual(shadowName, "remote-C.txt", "The restored row's shadow must hold the rename.")
    try await keepAttachments(AttachmentMatrixMember.remoteOrder.map(\.id), ofSnip: holder.snipID, in: holder.library)
    try await holder.sync.sync()

    try await downloaded.sync.fetchRemote()

    let local = try await downloaded.library.checkedSnapshot(sortedBy: .manual)
    let shown = try XCTUnwrap(local.snips.first(where: { $0.id == downloaded.snipID }))
    XCTAssertEqual(shown.attachments.map(\.id), [c, a, b], "The download-only device must take the reorder.")
    XCTAssertEqual(shown.attachments.first(where: { $0.id == c })?.fileName, "remote-C.txt",
      "The download-only device must show the rename its delete conflicted with.")
    try await assertAttachmentsSettle([(id: c, fileName: "remote-C.txt"), (id: a, fileName: "A.txt"),
      (id: b, fileName: "B.txt")], between: holder, and: downloaded)
  }

  // 4c: the delete's result is staged, the user restores the attachment, and the app relaunches
  // before the staged batch applies.
  func testAStagedDeleteAcknowledgementAppliedAfterARestoreReplans() async throws {
    let held = try await makeHeldMetadataDelete()
    let client = held.client
    defer { try? FileManager.default.removeItem(at: client.root) }
    try await client.store.stage(.sent(held.sent), outbound: held.outbound)
    try await restoreSnip(held.snip, in: client.library)
    try await client.library.reconcileCloudAttachments(
      namespaceKey: client.namespace.namespaceKey,
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let relaunched = try reopened(client)

    do {
      try await relaunched.store.applyStaged(held.sent.id)
    } catch {
      return XCTFail("A delete's result staged before the restore must replan, not throw \(error).")
    }

    let text = "edited after the relaunch"
    try await editText(ofSnip: client.snipID, to: text, in: relaunched.library)
    try await relaunched.sync.sync()
    try await relaunched.sync.sync()
    try await assertRestoreRepublished(held, in: relaunched, text: text)
  }

  // 4a and 4c already left staged batches on devices. An older build stored the delete's result
  // as accepted, which the restored attachment refuses on every replay.
  func testADeleteAcknowledgementStuckByAnOlderBuildReplansOnTheFirstSyncAfterUpgrade() async throws {
    let held = try await makeHeldMetadataDelete()
    let client = held.client
    defer { try? FileManager.default.removeItem(at: client.root) }
    try await restoreSnip(held.snip, in: client.library)
    _ = try await client.store.pendingChanges()
    let restoredStorage = try await snapshot(client.library, client.namespace)
    let restored = try XCTUnwrap(
      restoredStorage.publications.first,
      "The restored attachment must keep its publication."
    )
    XCTAssertTrue(restored.isLocallyPresent, "The restore must bring the attachment back.")
    try await client.store.stage(.sent(held.sent), outbound: held.outbound)
    let staged = try await client.store.stagedBatches()
    let batch = try XCTUnwrap(
      staged.first(where: { $0.batchID == held.sent.id }),
      "The delete's result must be staged."
    )
    let legacyBatch = stagedByAnOlderBuild(
      batch,
      attachmentTransitions: [.metadataDeleteAccepted(
        attachmentID: restored.metadata.attachmentID,
        expectedRevision: restored.revision
      )]
    )
    try await client.library.replaceStagedCloudFullBatch(legacyBatch)
    do {
      _ = try await client.library.commitCloudFullBatch(legacyBatch)
      XCTFail("The legacy transition must reproduce the old build's stuck batch.")
    } catch let error as CloudAttachmentStorageError {
      XCTAssertEqual(error, .staleTransition, "A present row must reject the legacy delete acceptance.")
    }
    let upgraded = try reopened(client)
    let persisted = try await upgraded.store.stagedBatches()
    XCTAssertEqual(persisted, [legacyBatch], "The upgrade must start with the exact stuck batch on disk.")

    do {
      try await upgraded.sync.sync()
    } catch {
      return XCTFail("The first sync after upgrading must replan the stuck batch, not throw \(error).")
    }

    let remaining = try await upgraded.store.stagedBatches()
    XCTAssertEqual(remaining, [], "The first sync must commit the replanned batch.")
    let firstSyncStorage = try await snapshot(upgraded.library, upgraded.namespace)
    let firstSyncPublication = try XCTUnwrap(
      firstSyncStorage.publications.first,
      "The first sync must retain the restored attachment."
    )
    XCTAssertNotEqual(
      firstSyncPublication.metadata.attachmentID,
      restored.metadata.attachmentID,
      "The first sync must remap the restored attachment and make progress."
    )
    let firstSyncRecord = await upgraded.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(firstSyncPublication.metadata.payloadIdentity)
    )
    XCTAssertNotNil(firstSyncRecord, "The first sync must upload the fresh payload.")
    XCTAssertNotEqual(firstSyncPublication.metadata.payloadIdentity, held.published.metadata.payloadIdentity)
    XCTAssertFalse(firstSyncPublication.metadataAccepted)
    let text = "edited after the upgrade"
    try await editText(ofSnip: client.snipID, to: text, in: upgraded.library)
    try await upgraded.sync.sync()
    try await assertRestoreRepublished(held, in: upgraded, text: text)
  }

  func testAHeldMetadataAcknowledgementPreservesAnUnreconciledPrependOnTheFileHolder() async throws {
    let clients = try await makeAttachmentEditClients()
    let holder = clients.holder
    defer { try? FileManager.default.removeItem(at: holder.root) }
    let held = try await holdCRenameForPlacementTest(in: holder)
    let n = AttachmentMatrixMember.n.id
    try await insertUnreconciledAttachment(id: n, fileName: "N.txt", at: 0, in: holder)

    try await holder.store.stage(.sent(held.sent), outbound: held.outbound)
    try await holder.store.applyStaged(held.sent.id)
    try await holder.transport.confirmApplied(held.sent.id)

    let expected = [n] + AttachmentMatrixMember.initial.map(\.id)
    let immediate = try await holder.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(immediate.snips.first(where: { $0.id == holder.snipID }))
    XCTAssertEqual(snip.attachments.map(\.id), expected, "An earlier acknowledgement must keep the unreconciled prepend.")
    try await assertPlacementSettlesKeepingCRename(expected, between: clients)
  }

  func testAHeldMetadataAcknowledgementPreservesARemovalBeforeAnUnreconciledAppend() async throws {
    let clients = try await makeAttachmentEditClients()
    let holder = clients.holder
    defer { try? FileManager.default.removeItem(at: holder.root) }
    let held = try await holdCRenameForPlacementTest(in: holder)
    let b = AttachmentMatrixMember.b.id
    let c = AttachmentMatrixMember.c.id
    let z = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    try await keepAttachments([b, c], ofSnip: holder.snipID, in: holder.library)

    try await holder.store.stage(.sent(held.sent), outbound: held.outbound)
    try await holder.store.applyStaged(held.sent.id)
    try await holder.transport.confirmApplied(held.sent.id)

    let afterAcknowledgement = try await holder.library.storedAttachmentReferencePositions(for: holder.snipID)
    XCTAssertEqual(afterAcknowledgement, [b: 0, c: 1], "The acknowledgement must leave the unreconciled removal's coordinates intact.")
    try await insertUnreconciledAttachment(id: z, fileName: "Z.txt", at: 2, in: holder)
    let expected = [b, c, z]
    let immediate = try await holder.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(immediate.snips.first(where: { $0.id == holder.snipID }))
    XCTAssertEqual(snip.attachments.map(\.id), expected, "The append must follow C without a stale-coordinate tie.")
    try await assertPlacementSettlesKeepingCRename(expected, between: clients)
  }

  // P6-1 (sm33-rfl-2 pass 6): a partial fetch delivers B1 while A's fetch fails, and the plan
  // records B0. An unreconciled append is present when B0's acknowledgement applies. Once that
  // append is removed, the next append must still follow B.
  func testAHeldSparseAcknowledgementLeavesNoStaleCoordinateForALaterAppend() async throws {
    let holder = try await makeAttachmentEditHolder(attachmentCount: 2)
    defer { try? FileManager.default.removeItem(at: holder.root) }
    let receiver = try attachmentClient(root: holder.root,
      storeURL: holder.root.appendingPathComponent("sparse.store"), namespace: holder.namespace,
      server: holder.server, snipID: holder.snipID)
    let a = AttachmentMatrixMember.a.id
    let b = AttachmentMatrixMember.b.id
    let n = AttachmentMatrixMember.n.id
    let z = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    let published = try await snapshot(holder.library, holder.namespace)
    let aRow = try publication(of: a, in: published)
    await receiver.transport.failNextFetchedItem(
      CloudAttachmentRecordCodec.recordID(aRow.metadataIdentity), failure: .retryable
    )
    try await receiver.sync.fetchRemote()
    let outbound = try await receiver.store.pendingChanges()
    let partialStorage = try await snapshot(receiver.library, receiver.namespace)
    let bRow = try publication(of: b, in: partialStorage)
    let bID = CloudAttachmentRecordCodec.recordID(bRow.metadataIdentity)
    XCTAssertTrue(outbound.operations.contains(where: { operation in
      guard case .save(let draft) = operation else { return false }
      return draft.id == bID && draft.encryptedFields["position"] == .int64(0)
    }), "The partial plan must record B0.")
    let sent = try await receiver.transport.send(outbound)
    try await insertUnreconciledAttachment(id: n, fileName: "N.txt", at: 1, in: receiver)

    try await receiver.store.stage(.sent(sent), outbound: outbound)
    try await receiver.store.applyStaged(sent.id)
    try await receiver.transport.confirmApplied(sent.id)
    try await keepAttachments([b], ofSnip: receiver.snipID, in: receiver.library)
    try await insertUnreconciledAttachment(id: z, fileName: "Z.txt", at: 1, in: receiver)

    let immediate = try await receiver.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(immediate.snips.first(where: { $0.id == receiver.snipID }))
    XCTAssertEqual(snip.attachments.map(\.id), [b, z], "The append must follow B.")
    let positions = try await receiver.library.storedAttachmentReferencePositions(for: receiver.snipID)
    XCTAssertEqual(positions, [b: 0, z: 1], "Stored positions must be canonical.")
    let acknowledged = try await snapshot(receiver.library, receiver.namespace)
    XCTAssertTrue(try publication(of: b, in: acknowledged).metadataAccepted, "B0 must be acknowledged.")
    let remote = await holder.server.fullSnapshot(for: bID)
    XCTAssertEqual(remote?.encryptedFields["position"], .int64(Int64(positions[b] ?? -1)),
      "B's stored position must match iCloud's.")

    for _ in 0..<3 {
      try await receiver.sync.sync()
      try await holder.sync.sync()
    }
    let order = try await assertSettledAttachmentOrder([a, b, z], between: receiver, and: holder)
    XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: b)), try XCTUnwrap(order.firstIndex(of: z)),
      "B must stay before Z on both devices and in iCloud.")
  }

  func testRevertingAReorderDuringItsSaveKeepsTheRevertAfterTheAcknowledgement() async throws {
    let clients = try await makeAttachmentEditClients()
    let holder = clients.holder
    defer { try? FileManager.default.removeItem(at: holder.root) }
    let original = AttachmentMatrixMember.initial.map(\.id)
    try await keepAttachments(AttachmentMatrixMember.localOrder.map(\.id), ofSnip: holder.snipID, in: holder.library)
    let outbound = try await holder.store.pendingChanges()
    let sent = try await holder.transport.send(outbound)
    try await keepAttachments(original, ofSnip: holder.snipID, in: holder.library)

    try await holder.store.stage(.sent(sent), outbound: outbound)
    try await holder.store.applyStaged(sent.id)
    try await holder.transport.confirmApplied(sent.id)

    let immediate = try await holder.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(immediate.snips.first(where: { $0.id == holder.snipID }))
    XCTAssertEqual(snip.attachments.map(\.id), original, "The reorder's acknowledgement must keep the revert made during its save.")
    try await assertPlacementSettles(original, between: clients)
  }

  // SM33 D7 (Primary-2): CloudKit stores an attachment edit, but Snip Snap quits before applying
  // the result. After the relaunch the user undoes the edit, and a fetch brings back the stored
  // save before reconcile records the undo.
  func testAnUndoneRenameSurvivesFetchingItsUnacknowledgedSaveOnTheDeviceHoldingTheFiles() async throws {
    try await assertAnUndoneEditSurvivesFetchingItsUnacknowledgedSave(on: .holder) { client in
      try await self.renameAttachment(ofSnip: client.snipID, attachmentID: AttachmentMatrixMember.a.id,
        to: "sent A.txt", in: client.library)
    }
  }

  func testAnUndoneRenameSurvivesFetchingItsUnacknowledgedSaveOnADownloadOnlyDevice() async throws {
    try await assertAnUndoneEditSurvivesFetchingItsUnacknowledgedSave(on: .downloaded) { client in
      try await self.renameAttachment(ofSnip: client.snipID, attachmentID: AttachmentMatrixMember.a.id,
        to: "sent A.txt", in: client.library)
    }
  }

  func testAnUndoneReorderSurvivesFetchingItsUnacknowledgedSaveOnTheDeviceHoldingTheFiles() async throws {
    try await assertAnUndoneEditSurvivesFetchingItsUnacknowledgedSave(on: .holder) { client in
      try await self.keepAttachments(AttachmentMatrixMember.localOrder.map(\.id), ofSnip: client.snipID,
        in: client.library)
    }
  }

  func testAnUndoneReorderSurvivesFetchingItsUnacknowledgedSaveOnADownloadOnlyDevice() async throws {
    try await assertAnUndoneEditSurvivesFetchingItsUnacknowledgedSave(on: .downloaded) { client in
      try await self.keepAttachments(AttachmentMatrixMember.localOrder.map(\.id), ofSnip: client.snipID,
        in: client.library)
    }
  }

  // Primary-2-R1 (sm33-rfl-3 pass 2): the recovery fetch brings back B's stored save while A's
  // record fails, so only part of the unacknowledged order returns. The undone order must stand.
  func testAnUndoneReorderSurvivesAPartialFetchOfItsUnacknowledgedSaveOnTheDeviceHoldingTheFiles() async throws {
    try await assertAnUndoneEditSurvivesFetchingItsUnacknowledgedSave(on: .holder, failingFirstFetchOf: .a) { client in
      try await self.keepAttachments(AttachmentMatrixMember.localOrder.map(\.id), ofSnip: client.snipID,
        in: client.library)
    }
  }

  func testAnUndoneReorderSurvivesAPartialFetchOfItsUnacknowledgedSaveOnADownloadOnlyDevice() async throws {
    try await assertAnUndoneEditSurvivesFetchingItsUnacknowledgedSave(on: .downloaded, failingFirstFetchOf: .a) { client in
      try await self.keepAttachments(AttachmentMatrixMember.localOrder.map(\.id), ofSnip: client.snipID,
        in: client.library)
    }
  }

  // Adversarial F1 (sm33-rfl-3 pass 2): a new attachment still waiting for its upload has no
  // acknowledged base, so it must not stop the fetched save from serving as the order's base.
  func testAnUndoneReorderBesideAnUnpublishedAddSurvivesFetchingItsUnacknowledgedSaveOnTheDeviceHoldingTheFiles() async throws {
    try await assertAnUndoneReorderBesideAnUnpublishedAddSurvivesFetchingItsUnacknowledgedSave(on: .holder)
  }

  func testAnUndoneReorderBesideAnUnpublishedAddSurvivesFetchingItsUnacknowledgedSaveOnADownloadOnlyDevice() async throws {
    try await assertAnUndoneReorderBesideAnUnpublishedAddSurvivesFetchingItsUnacknowledgedSave(on: .downloaded)
  }

  // SM33 D7b known gap: once reconcile records the undo, nothing shows what was sent, so the
  // fetched save can replace the undo. This guard checks only that both devices and iCloud agree
  // and go quiet. It doesn't assert which name wins.
  func testAnUndoRecordedBeforeFetchingItsUnacknowledgedSaveStillSettles() async throws {
    let clients = try await makeAttachmentEditClients()
    let holder = clients.holder
    defer { try? FileManager.default.removeItem(at: holder.root) }
    let a = AttachmentMatrixMember.a.id
    let before = try await holder.library.checkedSnapshot(sortedBy: .manual)
    let original = try XCTUnwrap(before.snips.first(where: { $0.id == holder.snipID })).attachments
    try await renameAttachment(ofSnip: holder.snipID, attachmentID: a, to: "sent A.txt", in: holder.library)
    let relaunched = try await relaunchAfterCloudKitStoresAnUnacknowledgedEdit(holder)
    let undone = try await snips(restoring: original, in: relaunched)
    _ = try await relaunched.library.perform(.replaceAll(undone), sortedBy: .manual)
    _ = try await relaunched.store.pendingChanges()

    try await relaunched.sync.fetchRemote()

    for _ in 0..<3 {
      try await relaunched.sync.sync()
      try await clients.downloaded.sync.sync()
    }
    let order = try await assertSettledAttachmentOrder(Set(original.map(\.id)), between: relaunched,
      and: clients.downloaded)
    XCTAssertEqual(order, original.map(\.id))
    let storage = try await snapshot(relaunched.library, relaunched.namespace)
    let row = try publication(of: a, in: storage)
    let remote = await holder.server.fullSnapshot(for: CloudAttachmentRecordCodec.recordID(row.metadataIdentity))
    let settledName = try XCTUnwrap(remote?.encryptedFields["fileName"])
    for client in [relaunched, clients.downloaded] {
      let local = try await client.library.checkedSnapshot(sortedBy: .manual)
      let snip = try XCTUnwrap(local.snips.first(where: { $0.id == client.snipID }))
      let shown = try XCTUnwrap(snip.attachments.first(where: { $0.id == a }))
      XCTAssertEqual(settledName, .string(shown.fileName), "Each device must show iCloud's name.")
    }
  }

  func testAnUnreconciledPrependKeepsItsPlaceWhenARemoteReorderArrives() async throws {
    let clients = try await makeAttachmentEditClients()
    let holder = clients.holder
    let peer = clients.downloaded
    defer { try? FileManager.default.removeItem(at: holder.root) }
    let n = AttachmentMatrixMember.n.id
    try await insertUnreconciledAttachment(id: n, fileName: "N.txt", at: 0, in: holder)
    try await keepAttachments(AttachmentMatrixMember.remoteOrder.map(\.id), ofSnip: peer.snipID, in: peer.library)
    try await peer.sync.sync()

    try await holder.sync.fetchRemote()

    let expected = [n] + AttachmentMatrixMember.remoteOrder.map(\.id)
    let immediate = try await holder.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(immediate.snips.first(where: { $0.id == holder.snipID }))
    XCTAssertEqual(snip.attachments.map(\.id), expected, "The prepend must stay first beside the remote reorder.")
    try await assertPlacementSettles(expected, between: clients)
  }

  func testAnUnreconciledRemovalLeavesNoGapWhenARemoteRenameArrives() async throws {
    let clients = try await makeAttachmentEditClients()
    let holder = clients.holder
    let peer = clients.downloaded
    defer { try? FileManager.default.removeItem(at: holder.root) }
    let b = AttachmentMatrixMember.b.id
    let c = AttachmentMatrixMember.c.id
    let z = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    try await keepAttachments([b, c], ofSnip: holder.snipID, in: holder.library)
    try await renameAttachment(ofSnip: peer.snipID, attachmentID: c, to: "renamed C.txt", in: peer.library)
    try await peer.sync.sync()

    try await holder.sync.fetchRemote()
    try await insertUnreconciledAttachment(id: z, fileName: "Z.txt", at: 2, in: holder)

    let expected = [b, c, z]
    let immediate = try await holder.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(immediate.snips.first(where: { $0.id == holder.snipID }))
    XCTAssertEqual(snip.attachments.map(\.id), expected, "The append must follow C without a stale-coordinate tie.")
    try await assertPlacementSettlesKeepingCRename(expected, between: clients)
  }

  // 4e: the user renames an attachment, then renames it again while the first save is in flight.
  func testAnEditDuringAnInFlightMetadataSaveStaysPendingAfterTheSaveIsAccepted() async throws {
    let client = try await makeAttachmentClient(fileNames: ["a"])
    defer { try? FileManager.default.removeItem(at: client.root) }
    try await client.sync.sync()
    try await client.sync.sync()
    try await renameAttachment(ofSnip: client.snipID, to: "b.txt", in: client.library)
    let outbound = try await client.store.pendingChanges()
    let storage = try await snapshot(client.library, client.namespace)
    let renamed = try XCTUnwrap(storage.publications.first, "The attachment must keep its publication.")
    let metadataID = CloudAttachmentRecordCodec.recordID(renamed.metadataIdentity)
    XCTAssertTrue(
      outbound.operations.contains(where: { operation in
        if case .save(let draft) = operation { draft.id == metadataID } else { false }
      }),
      "The first rename must plan a metadata save."
    )
    let sent = try await client.transport.send(outbound)
    guard case .saved(let savedRecord)? = sent.items.first(where: { $0.id == metadataID }) else {
      return XCTFail("CloudKit must accept the first rename.")
    }
    try await renameAttachment(ofSnip: client.snipID, to: "c.txt", in: client.library)
    _ = try await client.store.pendingChanges()

    try await client.store.stage(.sent(sent), outbound: outbound)
    try await client.store.applyStaged(sent.id)
    try await client.transport.confirmApplied(sent.id)

    let acknowledgedStorage = try await snapshot(client.library, client.namespace)
    let acknowledged = try XCTUnwrap(
      acknowledgedStorage.publications.first,
      "The attachment must keep its publication."
    )
    XCTAssertFalse(
      acknowledged.metadataAccepted,
      "The second rename must stay pending after CloudKit accepts the first."
    )
    XCTAssertEqual(acknowledged.metadata.fileName, "c.txt", "The second rename must survive.")
    XCTAssertEqual(
      acknowledged.metadataShadowData,
      savedRecord.shadow.data,
      "The accepted save must become the base for the pending rename."
    )

    try await client.sync.sync()

    let serverRecord = await client.server.fullSnapshot(for: metadataID)
    XCTAssertEqual(
      serverRecord?.encryptedFields["fileName"],
      .string("c.txt"),
      "CloudKit must end with the second rename."
    )
  }

  // 5: the user removes an attachment while its first metadata save is in flight. The save lands.
  func testRemovingAnAttachmentDuringItsFirstMetadataSaveLeavesNoAttachmentAnywhere() async throws {
    try await assertRemovalDuringTheFirstMetadataSaveLeavesNoAttachment(relaunching: false)
  }

  func testRemovingAnAttachmentDuringItsFirstMetadataSaveKeepsItsPublicationAcrossARelaunch() async throws {
    try await assertRemovalDuringTheFirstMetadataSaveLeavesNoAttachment(relaunching: true)
  }

  // 5, unknown item: the removed attachment's first save finds no record, so CloudKit holds no
  // metadata for it.
  func testRemovingAnAttachmentWhoseFirstMetadataSaveCameBackUnknownSettlesItsCleanup() async throws {
    let client = try await makeAttachmentClient(fileNames: ["unknown-first-save"])
    defer { try? FileManager.default.removeItem(at: client.root) }
    try await client.sync.sync()
    let accepted = try await snapshot(client.library, client.namespace)
    let publication = try XCTUnwrap(accepted.publications.first, "The first sync must keep the publication.")
    XCTAssertTrue(publication.payloadAccepted, "The first sync must accept the payload.")
    let metadataID = CloudAttachmentRecordCodec.recordID(publication.metadataIdentity)
    let payloadID = CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity)
    let outbound = try await client.store.pendingChanges()
    let metadataSave = try XCTUnwrap(
      outbound.operations.first(where: { $0.id == metadataID }),
      "The second plan must save the metadata."
    )
    try await keepAttachments([], ofSnip: client.snipID, in: client.library)
    _ = try await client.store.pendingChanges()
    let submitted = CloudOutboundBatch(operations: [metadataSave])
    let sent = CloudSentBatch(
      id: UUID(),
      items: [.unknownItem(metadataID)],
      engineState: try await client.store.loadEngineState()
    )

    try await client.store.stage(.sent(sent), outbound: submitted)
    try await client.store.applyStaged(sent.id)

    let settled = try await snapshot(client.library, client.namespace)
    XCTAssertEqual(settled.publications, [], "CloudKit holds no metadata for it, so the removal must settle.")
    XCTAssertEqual(
      settled.cleanups.map(\.identity),
      [publication.metadata.payloadIdentity],
      "The accepted payload must be owed its cleanup."
    )
    XCTAssertEqual(
      settled.cleanups.first?.shadowData,
      publication.payloadShadowData,
      "The cleanup must delete from the accepted payload shadow."
    )

    try await client.sync.sync()

    let payloadRecord = await client.server.fullSnapshot(for: payloadID)
    XCTAssertNil(payloadRecord, "The cleanup must delete the payload.")
    let cleaned = try await snapshot(client.library, client.namespace)
    XCTAssertEqual(cleaned.cleanups, [], "The cleanup must settle.")
  }

  // 7b: the user removes an attachment while its first upload is in flight. The upload lands.
  func testRemovingAnAttachmentDuringItsFirstUploadDeletesTheUploadedPayload() async throws {
    try await assertRemovalDuringTheFirstUploadDeletesThePayload(relaunching: false)
  }

  func testRemovingAnAttachmentDuringItsFirstUploadDeletesTheUploadedPayloadAfterARelaunch() async throws {
    try await assertRemovalDuringTheFirstUploadDeletesThePayload(relaunching: true)
  }

  // 7b guard: an attachment removed before its upload starts is owed the same cleanup. It finds
  // nothing in CloudKit and settles in one sync.
  func testRemovingAnAttachmentBeforeItsUploadStartsSettlesItsCleanup() async throws {
    let client = try await makeAttachmentClient(fileNames: ["never-uploaded"])
    defer { try? FileManager.default.removeItem(at: client.root) }
    _ = try await client.store.pendingChanges()
    try await keepAttachments([], ofSnip: client.snipID, in: client.library)

    try await client.sync.sync()

    let settled = try await snapshot(client.library, client.namespace)
    XCTAssertEqual(settled.publications, [], "The removed attachment must keep no publication.")
    XCTAssertEqual(settled.cleanups, [], "A cleanup for a payload CloudKit never got must settle in one sync.")
    let issue = try await client.store.unresolvedSyncIssue()
    XCTAssertNil(issue, "The removal must leave no sync issue.")
  }

  func testAnAbandonedUploadFailureDoesNotFailItsCleanup() async throws {
    for failure in [CloudOperationFailure.quotaExceeded, .zoneMissing] {
      let client = try await makeAttachmentClient(fileNames: [])
      defer { try? FileManager.default.removeItem(at: client.root) }
      try await client.sync.sync()
      let source = client.root.appendingPathComponent("abandoned.txt")
      try Data("abandoned bytes".utf8).write(to: source)
      let local = try await client.library.checkedSnapshot(sortedBy: .manual)
      let snip = try XCTUnwrap(local.snips.first, "The fixture must publish its snip.")
      _ = try await client.library.perform(.editAttachments(
        snipID: snip.id,
        content: snip.content,
        edits: [.added(sourceURL: source)],
        expectedUpdatedAt: snip.updatedAt,
        now: Date(timeIntervalSince1970: 1)
      ), sortedBy: .manual)
      let outbound = try await client.store.pendingChanges()
      let pending = try await snapshot(client.library, client.namespace)
      let publication = try XCTUnwrap(pending.publications.first, "The fixture must queue its upload.")
      let payloadID = CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity)
      let save = try XCTUnwrap(outbound.operations.first(where: { $0.id == payloadID }), "The first plan must save the payload.")
      try await keepAttachments([], ofSnip: client.snipID, in: client.library)
      _ = try await client.store.pendingChanges()
      let removed = try await snapshot(client.library, client.namespace)
      let namespaceBefore = try await client.library.cloudFullStorageSnapshot(namespaceKey: client.namespace.namespaceKey)
      let sent = CloudSentBatch(
        id: UUID(),
        items: [.failed(payloadID, failure)],
        engineState: try await client.store.loadEngineState()
      )

      try await client.store.stage(.sent(sent), outbound: CloudOutboundBatch(operations: [save]))
      try await client.store.applyStaged(sent.id)

      let acknowledged = try await snapshot(client.library, client.namespace)
      XCTAssertEqual(acknowledged, removed, "An abandoned save failure must not change its cleanup: \(failure).")
      let fullStorage = try await client.library.cloudFullStorageSnapshot(namespaceKey: client.namespace.namespaceKey)
      XCTAssertEqual(fullStorage.namespaceState.phase, namespaceBefore.namespaceState.phase, "A discarded row's abandoned save must not trigger zone recovery.")
    }
  }

  // 9: the user replaces a published attachment's bytes, then removes it before the new bytes
  // upload. CloudKit still holds metadata that names the old payload.
  func testRemovingAnAttachmentAfterItsFileWasReplacedDeletesItsMetadataAndBothPayloads() async throws {
    let client = try await makeAttachmentClient(fileNames: ["replaced"])
    defer { try? FileManager.default.removeItem(at: client.root) }
    try await client.sync.sync()
    try await client.sync.sync()
    // Consume our published metadata so a later fetch cannot mask the removal's pending phase.
    try await client.sync.fetchRemote()
    let publishedStorage = try await snapshot(client.library, client.namespace)
    let published = try XCTUnwrap(publishedStorage.publications.first, "The attachment must publish.")
    XCTAssertTrue(published.metadataAccepted, "The attachment's metadata must publish.")
    let durableFile = try XCTUnwrap(published.localSourceURL, "The attachment must keep its local file.")
    try Data("replacement bytes that never upload".utf8).write(to: durableFile)
    _ = try await client.store.pendingChanges()
    let replacedStorage = try await snapshot(client.library, client.namespace)
    let replaced = try XCTUnwrap(replacedStorage.publications.first, "The attachment must keep its publication.")
    XCTAssertEqual(
      replaced.priorPayloadIdentity,
      published.metadata.payloadIdentity,
      "The published payload must wait as the replaced payload."
    )
    let payloadIDs = [published.metadata.payloadIdentity, replaced.metadata.payloadIdentity]
      .map(CloudAttachmentRecordCodec.recordID)
    try await keepAttachments([], ofSnip: client.snipID, in: client.library)

    for _ in 0..<3 { try await client.sync.sync() }

    let metadataRecord = await client.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(published.metadataIdentity)
    )
    XCTAssertNil(metadataRecord, "The removal must delete the published metadata.")
    for payloadID in payloadIDs {
      let payloadRecord = await client.server.fullSnapshot(for: payloadID)
      XCTAssertNil(payloadRecord, "No payload of the removed attachment may stay in CloudKit.")
    }
    let settled = try await snapshot(client.library, client.namespace)
    XCTAssertEqual(settled.publications, [], "The removal must settle its publication.")
    XCTAssertEqual(settled.cleanups, [], "The removal must settle every cleanup.")
  }

  func testFetchingAnUnacknowledgedMetadataDeleteAfterReplacementRemovesBothPayloads() async throws {
    let client = try await makeAttachmentClient(fileNames: ["replaced"])
    defer { try? FileManager.default.removeItem(at: client.root) }
    try await client.sync.sync()
    try await client.sync.sync()
    // Consume our published metadata so a later fetch cannot mask the removal's pending phase.
    try await client.sync.fetchRemote()
    let publishedStorage = try await snapshot(client.library, client.namespace)
    let published = try XCTUnwrap(publishedStorage.publications.first, "The attachment must publish.")
    XCTAssertTrue(published.metadataAccepted, "The attachment's metadata must publish.")
    let durableFile = try XCTUnwrap(published.localSourceURL, "The attachment must keep its local file.")
    try Data("replacement bytes that never upload".utf8).write(to: durableFile)
    _ = try await client.store.pendingChanges()
    let replacedStorage = try await snapshot(client.library, client.namespace)
    let replaced = try XCTUnwrap(replacedStorage.publications.first, "The attachment must keep its publication.")
    XCTAssertFalse(replaced.payloadAccepted, "The replacement payload must still be pending.")
    XCTAssertEqual(
      replaced.priorPayloadIdentity,
      published.metadata.payloadIdentity,
      "The published payload must wait as the replaced payload."
    )
    let payloadIDs = [published.metadata.payloadIdentity, replaced.metadata.payloadIdentity]
      .map(CloudAttachmentRecordCodec.recordID)
    try await keepAttachments([], ofSnip: client.snipID, in: client.library)

    let outbound = try await client.store.pendingChanges()
    let metadataID = CloudAttachmentRecordCodec.recordID(published.metadataIdentity)
    XCTAssertTrue(outbound.operations.contains(where: { operation in
      if case .delete(let id, _) = operation { id == metadataID } else { false }
    }), "The removal must plan the metadata delete.")
    // CloudKit applies the delete, but the app dies before staging its returned batch.
    _ = try await client.transport.send(outbound)
    let deletedMetadata = await client.server.fullSnapshot(for: metadataID)
    XCTAssertNil(deletedMetadata, "The server must apply the metadata delete before the relaunch.")
    let staged = try await client.store.stagedBatches()
    XCTAssertEqual(staged, [], "The sent result must not be staged before the relaunch.")
    let relaunched = try reopened(client)

    // Start the fresh transport directly so no outbound plan precedes the fetched tombstone.
    let persistedState = try await relaunched.store.loadEngineState()
    XCTAssertNotNil(persistedState, "The relaunch must restore the persisted fetch cursors.")
    try await relaunched.transport.start(state: persistedState)
    let fetched = try await relaunched.transport.fetch(scope: .zones([
      CloudZoneID(name: "data", ownerName: "owner")
    ]))
    XCTAssertTrue(fetched.items.contains(where: { item in
      if case .deleted(let id) = item { id == metadataID } else { false }
    }), "The restored cursor must fetch the unstaged metadata deletion.")
    try await relaunched.store.stage(.fetched(fetched))
    try await relaunched.store.applyStaged(fetched.id)
    try await relaunched.transport.confirmApplied(fetched.id)
    for _ in 0..<3 { try await relaunched.sync.sync() }

    let metadataRecord = await client.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(published.metadataIdentity)
    )
    XCTAssertNil(metadataRecord, "The removal must delete the published metadata.")
    for payloadID in payloadIDs {
      let payloadRecord = await client.server.fullSnapshot(for: payloadID)
      XCTAssertNil(payloadRecord, "No payload of the removed attachment may stay in CloudKit.")
    }
    let settled = try await snapshot(relaunched.library, relaunched.namespace)
    XCTAssertEqual(settled.publications, [], "The removal must settle its publication.")
    XCTAssertEqual(settled.cleanups, [], "The removal must settle every cleanup.")
  }

  // 6: this device adopts metadata that names a payload it had replaced, then publishes an edit.
  // The replaced payload's cleanup comes due while live metadata names it.
  func testACleanupNeverDeletesAPayloadThatLiveMetadataNames() async throws {
    let fixture = try await makePendingAttachmentFixture(names: ["live"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pendingStorage = try await snapshot(fixture.library, fixture.namespace)
    let pending = try XCTUnwrap(
      pendingStorage.publications.first,
      "The fixture must queue its attachment."
    )
    let payloadRecord = try payloadShadow(pending.metadata.payloadIdentity)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.payloadAccepted(
        attachmentID: pending.metadata.attachmentID,
        expectedRevision: pending.revision,
        shadowData: payloadRecord.data,
        systemFields: payloadRecord.systemFields
      )]
    )
    let metadataRecord = try metadataShadow(pending.metadataIdentity)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.metadataAccepted(
        attachmentID: pending.metadata.attachmentID,
        expectedRevision: pending.revision + 1,
        shadowData: metadataRecord.data,
        systemFields: metadataRecord.systemFields
      )]
    )
    let publishedStorage = try await snapshot(fixture.library, fixture.namespace)
    let published = try XCTUnwrap(
      publishedStorage.publications.first,
      "The attachment must publish."
    )
    let livePayload = published.metadata.payloadIdentity
    let durableFile = try XCTUnwrap(published.localSourceURL, "The attachment must keep its local file.")
    let originalBytes = try Data(contentsOf: durableFile)
    try Data("bytes this device replaced".utf8).write(to: durableFile)
    _ = try await fixture.store.pendingChanges()
    let replacedStorage = try await snapshot(fixture.library, fixture.namespace)
    let replaced = try XCTUnwrap(
      replacedStorage.publications.first,
      "The attachment must keep its publication."
    )
    XCTAssertEqual(replaced.priorPayloadIdentity, livePayload, "The published payload must wait as replaced.")
    // Reverting the local file lets the next reconcile retain the server's original payload.
    try originalBytes.write(to: durableFile)
    let remoteRecord = try metadataShadow(replaced.metadataIdentity)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.remoteMetadataAccepted(
        metadata: published.metadata,
        metadataIdentity: replaced.metadataIdentity,
        shadowData: remoteRecord.data,
        systemFields: remoteRecord.systemFields
      )]
    )
    try await renameAttachment(
      ofSnip: replaced.metadata.snipID,
      to: "renamed here.txt",
      in: fixture.library
    )
    _ = try await fixture.store.pendingChanges()
    let editedStorage = try await snapshot(fixture.library, fixture.namespace)
    let edited = try XCTUnwrap(
      editedStorage.publications.first,
      "The attachment must keep its publication."
    )
    XCTAssertEqual(edited.metadata.payloadIdentity, livePayload, "The adopted metadata must name the live payload.")
    XCTAssertFalse(edited.metadataAccepted, "The local rename must wait to sync.")
    let acceptedRecord = try metadataShadow(edited.metadataIdentity)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.metadataAccepted(
        attachmentID: edited.metadata.attachmentID,
        expectedRevision: edited.revision,
        shadowData: acceptedRecord.data,
        systemFields: acceptedRecord.systemFields
      )]
    )
    let accepted = try await snapshot(fixture.library, fixture.namespace)
    XCTAssertEqual(
      accepted.publications.first?.metadata.payloadIdentity,
      livePayload,
      "The accepted metadata must still name the live payload."
    )
    XCTAssertTrue(
      accepted.cleanups.contains(where: { $0.identity == livePayload }),
      "The replaced payload's cleanup is due, so only the planner can keep the live payload."
    )

    let plan = try await fixture.store.pendingChanges()

    XCTAssertFalse(
      plan.operations.contains(where: { $0.id == CloudAttachmentRecordCodec.recordID(livePayload) }),
      "A cleanup must never delete a payload that a publication names."
    )
  }

  private func assertRemovalDuringTheFirstMetadataSaveLeavesNoAttachment(
    relaunching: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let client = try await makeAttachmentClient(fileNames: ["removed-while-publishing"])
    defer { try? FileManager.default.removeItem(at: client.root) }
    try await client.sync.sync()
    let accepted = try await snapshot(client.library, client.namespace)
    let publication = try XCTUnwrap(
      accepted.publications.first,
      "The first sync must keep the publication.",
      file: file,
      line: line
    )
    XCTAssertTrue(
      publication.payloadAccepted && !publication.metadataAccepted,
      "The first sync must accept only the payload.",
      file: file,
      line: line
    )
    let metadataID = CloudAttachmentRecordCodec.recordID(publication.metadataIdentity)
    let payloadID = CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity)
    let outbound = try await client.store.pendingChanges()
    XCTAssertTrue(
      outbound.operations.contains(where: { $0.id == metadataID }),
      "The second plan must save the metadata.",
      file: file,
      line: line
    )
    let sent = try await client.transport.send(outbound)
    let landed = await client.server.fullSnapshot(for: metadataID)
    XCTAssertNotNil(
      landed,
      "CloudKit must accept the metadata before its result comes back.",
      file: file,
      line: line
    )
    try await keepAttachments([], ofSnip: client.snipID, in: client.library)
    _ = try await client.store.pendingChanges()
    let session: AttachmentClient
    if relaunching {
      session = try reopened(client)
      let relaunchedStorage = try await snapshot(session.library, session.namespace)
      let kept = try XCTUnwrap(
        relaunchedStorage.publications.first,
        "CloudKit may be receiving its metadata, so the removed attachment must keep its publication.",
        file: file,
        line: line
      )
      XCTAssertFalse(kept.isLocallyPresent, "The kept publication must record the removal.", file: file, line: line)
    } else {
      session = client
    }

    try await session.store.stage(.sent(sent), outbound: outbound)
    try await session.store.applyStaged(sent.id)
    if !relaunching { try await client.transport.confirmApplied(sent.id) }
    for _ in 0..<3 { try await session.sync.sync() }

    let metadataRecord = await session.server.fullSnapshot(for: metadataID)
    XCTAssertNil(metadataRecord, "The metadata that landed after the removal must be deleted.", file: file, line: line)
    let payloadRecord = await session.server.fullSnapshot(for: payloadID)
    XCTAssertNil(payloadRecord, "The payload must be cleaned up after its metadata.", file: file, line: line)
    let other = try attachmentClient(
      root: session.root,
      storeURL: session.root.appendingPathComponent("other.store"),
      namespace: session.namespace,
      server: session.server,
      snipID: session.snipID
    )
    try await other.sync.fetchRemote()
    try await session.sync.fetchRemote()
    for (name, library) in [("client 1", session.library), ("client 2", other.library)] {
      let local = try await library.checkedSnapshot(sortedBy: .manual)
      let snip = try XCTUnwrap(
        local.snips.first(where: { $0.id == session.snipID }),
        "\(name) must hold the snip.",
        file: file,
        line: line
      )
      XCTAssertEqual(snip.attachments, [], "\(name) must show no attachment.", file: file, line: line)
      let storage = try await snapshot(library, session.namespace)
      XCTAssertEqual(storage.publications, [], "\(name) must keep no publication.", file: file, line: line)
    }
  }

  private func assertRemovalDuringTheFirstUploadDeletesThePayload(
    relaunching: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let client = try await makeAttachmentClient(fileNames: ["wrong-video"])
    defer { try? FileManager.default.removeItem(at: client.root) }
    let outbound = try await client.store.pendingChanges()
    let storage = try await snapshot(client.library, client.namespace)
    let pending = try XCTUnwrap(storage.publications.first, "The first plan must queue the upload.", file: file, line: line)
    let queuedUpload = try XCTUnwrap(pending.sourceURL, "The upload must have a queued copy.", file: file, line: line)
    let payloadID = CloudAttachmentRecordCodec.recordID(pending.metadata.payloadIdentity)
    XCTAssertTrue(
      outbound.operations.contains(where: { $0.id == payloadID }),
      "The first plan must upload the payload.",
      file: file,
      line: line
    )
    let sent = try await client.transport.send(outbound)
    let uploaded = await client.server.fullSnapshot(for: payloadID)
    XCTAssertNotNil(uploaded, "CloudKit must accept the upload before its result comes back.", file: file, line: line)
    try await keepAttachments([], ofSnip: client.snipID, in: client.library)
    _ = try await client.store.pendingChanges()
    let session = relaunching ? try reopened(client) : client

    try await session.store.stage(.sent(sent), outbound: outbound)
    try await session.store.applyStaged(sent.id)
    if !relaunching { try await client.transport.confirmApplied(sent.id) }
    try await session.sync.sync()
    try await session.sync.sync()

    let payloadRecord = await session.server.fullSnapshot(for: payloadID)
    XCTAssertNil(payloadRecord, "The upload that landed after the removal must be deleted.", file: file, line: line)
    let settled = try await snapshot(session.library, session.namespace)
    XCTAssertEqual(settled.publications, [], "The removed attachment must keep no publication.", file: file, line: line)
    XCTAssertEqual(settled.cleanups, [], "The abandoned upload's cleanup must settle.", file: file, line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: queuedUpload.deletingLastPathComponent().path),
      "No queued upload copy may outlive the removal.",
      file: file,
      line: line
    )
  }

  /// Client 1 publishes one attachment from a local file, removes it, and sends the metadata
  /// delete. CloudKit applies the delete, and its result has not come back yet.
  private func makeHeldMetadataDelete() async throws -> HeldMetadataDelete {
    let client = try await makeAttachmentClient(fileNames: ["restored"])
    // The first sync accepts the payload; the second publishes the metadata that names it.
    try await client.sync.sync()
    try await client.sync.sync()
    let publishedStorage = try await snapshot(client.library, client.namespace)
    let published = try XCTUnwrap(publishedStorage.publications.first, "The fixture must publish its attachment.")
    XCTAssertTrue(published.metadataAccepted, "The fixture must publish its attachment's metadata.")
    let local = try await client.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(
      local.snips.first(where: { $0.id == client.snipID }),
      "The fixture must keep its snip."
    )
    try await keepAttachments([], ofSnip: client.snipID, in: client.library)
    let outbound = try await client.store.pendingChanges()
    let metadataID = CloudAttachmentRecordCodec.recordID(published.metadataIdentity)
    XCTAssertTrue(
      outbound.operations.contains(where: { operation in
        if case .delete(let id, _) = operation { id == metadataID } else { false }
      }),
      "Removing the attachment must plan its metadata delete."
    )
    let sent = try await client.transport.send(outbound)
    let deletedRecord = await client.server.fullSnapshot(for: metadataID)
    XCTAssertNil(deletedRecord, "CloudKit must apply the delete before its result comes back.")
    return HeldMetadataDelete(
      client: client,
      published: published,
      snip: snip,
      outbound: outbound,
      sent: sent
    )
  }

  /// The restore republished the attachment under a new identity, and text kept syncing.
  private func assertRestoreRepublished(
    _ held: HeldMetadataDelete,
    in client: AttachmentClient,
    text: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let staged = try await client.store.stagedBatches()
    XCTAssertEqual(staged, [], "No staged batch may stay stuck.", file: file, line: line)
    let storedText = await client.server.storedTextValues()
    XCTAssertTrue(storedText.contains(text), "Text edits after the restore must sync.", file: file, line: line)
    let storage = try await snapshot(client.library, client.namespace)
    let republished = try XCTUnwrap(
      storage.publications.first,
      "The restored attachment must keep a publication.",
      file: file,
      line: line
    )
    XCTAssertNotEqual(
      republished.metadata.attachmentID,
      held.published.metadata.attachmentID,
      "CloudKit applied the delete, so the restore must republish under a new identity.",
      file: file,
      line: line
    )
    XCTAssertTrue(republished.metadataAccepted, "The republished metadata must be accepted.", file: file, line: line)
    let record = await client.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(republished.metadataIdentity)
    )
    XCTAssertNotNil(record, "CloudKit must hold the republished metadata.", file: file, line: line)
    let local = try await client.library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(
      local.snips.first(where: { $0.id == client.snipID })?.attachments.map(\.id),
      [republished.metadata.attachmentID],
      "The snip must list the restored attachment.",
      file: file,
      line: line
    )
  }

  /// The staged batch as an older build stored it, with these attachment transitions.
  private func stagedByAnOlderBuild(
    _ batch: CloudFullBatchCommit,
    attachmentTransitions: [CloudAttachmentTransition]
  ) -> CloudFullBatchCommit {
    CloudFullBatchCommit(
      namespaceKey: batch.namespaceKey,
      batchID: batch.batchID,
      expectedEngineState: batch.expectedEngineState,
      nextEngineState: batch.nextEngineState,
      nextEnrollment: batch.nextEnrollment,
      expectedNamespaceRevision: batch.expectedNamespaceRevision,
      nextNamespaceState: batch.nextNamespaceState,
      rawBatchData: batch.rawBatchData,
      outboundBindings: batch.outboundBindings,
      recoveryInputs: batch.recoveryInputs,
      recoveryChanges: batch.recoveryChanges,
      recoveryReviews: batch.recoveryReviews,
      graphRepairs: batch.graphRepairs,
      settledDeleteIdentities: batch.settledDeleteIdentities,
      attachmentTransitions: attachmentTransitions,
      items: batch.items
    )
  }


  /// The same store after a relaunch: a new library, persistence, transport, and coordinator.
  private func reopened(_ client: AttachmentClient) throws -> AttachmentClient {
    try attachmentClient(
      root: client.root,
      storeURL: client.storeURL,
      namespace: client.namespace,
      server: client.server,
      snipID: client.snipID
    )
  }




  /// Puts the snip back as it was before its attachments changed, as an undo does.
  private func restoreSnip(_ snip: Snip, in library: SwiftDataSnipLibrary) async throws {
    var snips = try await library.checkedSnapshot(sortedBy: .manual).snips
    let index = try XCTUnwrap(snips.firstIndex(where: { $0.id == snip.id }), "The snip must exist.")
    snips[index] = snip
    _ = try await library.perform(.replaceAll(snips), sortedBy: .manual)
  }


  private func holdCRenameForPlacementTest(
    in client: AttachmentClient
  ) async throws -> (outbound: CloudOutboundBatch, sent: CloudSentBatch) {
    let c = AttachmentMatrixMember.c.id
    try await renameAttachment(ofSnip: client.snipID, attachmentID: c,
      to: "renamed C.txt", in: client.library)
    let outbound = try await client.store.pendingChanges()
    let storage = try await snapshot(client.library, client.namespace)
    let row = try publication(of: c, in: storage)
    let metadataID = CloudAttachmentRecordCodec.recordID(row.metadataIdentity)
    XCTAssertTrue(outbound.operations.contains(where: { operation in
      if case .save(let draft) = operation { draft.id == metadataID } else { false }
    }), "C's rename must be recorded before the acknowledgement is held.")
    let sent = try await client.transport.send(outbound)
    XCTAssertTrue(sent.items.contains(where: { item in
      if case .saved(let record) = item { record.id == metadataID } else { false }
    }), "The held result must acknowledge C's rename.")
    return (outbound, sent)
  }

  private func insertUnreconciledAttachment(
    id: UUID, fileName: String, at position: Int, in client: AttachmentClient
  ) async throws {
    let snapshot = try await client.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(snapshot.snips.first(where: { $0.id == client.snipID }))
    let source = client.root.appendingPathComponent(fileName)
    try Data("\(fileName) payload".utf8).write(to: source)
    var edits = snip.attachments.map { SnipAttachmentEdit.existing(attachmentID: $0.id) }
    edits.insert(.added(sourceURL: source), at: position)
    let update = try await client.library.perform(.editAttachments(
      snipID: client.snipID, content: snip.content, edits: edits,
      expectedUpdatedAt: snip.updatedAt, now: Date(timeIntervalSince1970: 4)
    ), sortedBy: .manual)
    let edited = try XCTUnwrap(update.snapshot.snips.first(where: { $0.id == client.snipID }))
    let imported = try XCTUnwrap(edited.attachments.first(where: { $0.fileName == fileName }))
    try await client.library.setUnpublishedAttachmentID(imported.id, to: id, for: client.snipID)
  }

  private func assertPlacementSettles(
    _ expected: [UUID], between clients: AttachmentEditClients
  ) async throws {
    let holder = clients.holder
    let peer = clients.downloaded
    // Publish the new payload and its metadata before the peer reconciles an attachment subset.
    for _ in 0..<3 { try await holder.sync.sendPending() }
    for _ in 0..<2 {
      try await holder.sync.sync()
      try await peer.sync.sync()
    }
    let order = try await assertSettledAttachmentOrder(Set(expected), between: holder, and: peer)
    XCTAssertEqual(order, expected, "The local placement must reach both devices and the server.")
  }

  private func assertPlacementSettlesKeepingCRename(
    _ expected: [UUID], between clients: AttachmentEditClients
  ) async throws {
    try await assertPlacementSettles(expected, between: clients)
    let holder = clients.holder
    let peer = clients.downloaded
    let c = AttachmentMatrixMember.c.id
    for client in [holder, peer] {
      let snapshot = try await client.library.checkedSnapshot(sortedBy: .manual)
      let snip = try XCTUnwrap(snapshot.snips.first(where: { $0.id == client.snipID }))
      XCTAssertEqual(snip.attachments.first(where: { $0.id == c })?.fileName, "renamed C.txt")
    }
    let storage = try await snapshot(holder.library, holder.namespace)
    let renamed = try publication(of: c, in: storage)
    let record = await holder.server.fullSnapshot(for: CloudAttachmentRecordCodec.recordID(renamed.metadataIdentity))
    XCTAssertEqual(record?.encryptedFields["fileName"], .string("renamed C.txt"))
  }

  /// - Parameter failedMember: an attachment whose record the first fetch after the relaunch
  ///   fails to bring back, so only part of the stored save returns.
  private func assertAnUndoneEditSurvivesFetchingItsUnacknowledgedSave(
    on role: AttachmentMatrixRole,
    failingFirstFetchOf failedMember: AttachmentMatrixMember? = nil,
    file: StaticString = #filePath,
    line: UInt = #line,
    edit: (AttachmentClient) async throws -> Void
  ) async throws {
    let clients = try await makeAttachmentEditClients()
    defer { try? FileManager.default.removeItem(at: clients.holder.root) }
    let editor = role == .holder ? clients.holder : clients.downloaded
    let peer = role == .holder ? clients.downloaded : clients.holder
    let before = try await editor.library.checkedSnapshot(sortedBy: .manual)
    let original = try XCTUnwrap(before.snips.first(where: { $0.id == editor.snipID }),
      file: file, line: line).attachments
    try await edit(editor)
    let relaunched = try await relaunchAfterCloudKitStoresAnUnacknowledgedEdit(editor, file: file, line: line)
    let library = relaunched.library
    let undone = try await snips(restoring: original, in: relaunched)
    if let failedMember {
      let storage = try await snapshot(library, relaunched.namespace)
      let row = try publication(of: failedMember.id, in: storage)
      await relaunched.transport.failNextFetchedItem(CloudAttachmentRecordCodec.recordID(row.metadataIdentity),
        failure: .retryable)
    }

    // The undo lands after the engine starts and before the fetched save commits, so reconcile
    // never records it.
    try await relaunched.sync.fetchRemote(beforeApply: {
      _ = try await library.perform(.replaceAll(undone), sortedBy: .manual)
    })

    let local = try await relaunched.library.checkedSnapshot(sortedBy: .manual)
    let shown = try XCTUnwrap(local.snips.first(where: { $0.id == relaunched.snipID }),
      file: file, line: line).attachments
    XCTAssertEqual(shown.map(\.id), original.map(\.id),
      "Fetching the unacknowledged save must keep the undone order.", file: file, line: line)
    XCTAssertEqual(shown.map(\.fileName), original.map(\.fileName),
      "Fetching the unacknowledged save must keep the undone names.", file: file, line: line)
    if failedMember != nil {
      let positions = try await library.storedAttachmentReferencePositions(for: relaunched.snipID)
      XCTAssertEqual(positions, canonicalPositions(original.map(\.id)),
        "The partial fetch must leave the undone order's coordinates.", file: file, line: line)
    }
    try await assertAttachmentsSettle(original.map { (id: $0.id, fileName: $0.fileName) },
      between: relaunched, and: peer, file: file, line: line)
  }

  /// Like the undone-reorder check, with a new attachment whose upload fails before Snip Snap
  /// quits, so iCloud never holds its metadata.
  private func assertAnUndoneReorderBesideAnUnpublishedAddSurvivesFetchingItsUnacknowledgedSave(
    on role: AttachmentMatrixRole,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let clients = try await makeAttachmentEditClients()
    defer { try? FileManager.default.removeItem(at: clients.holder.root) }
    let editor = role == .holder ? clients.holder : clients.downloaded
    let peer = role == .holder ? clients.downloaded : clients.holder
    let before = try await editor.library.checkedSnapshot(sortedBy: .manual)
    let original = try XCTUnwrap(before.snips.first(where: { $0.id == editor.snipID }),
      file: file, line: line).attachments
    try await keepAttachments(AttachmentMatrixMember.localOrder.map(\.id), ofSnip: editor.snipID, in: editor.library)
    try await appendAttachment(.n, to: editor)
    let planned = try await editor.store.pendingChanges()
    let uploads = planned.operations.compactMap { operation -> CloudRecordID? in
      guard case .save(let draft) = operation,
        draft.recordType == CloudAttachmentRecordCodec.payloadRecordType
      else { return nil }
      return draft.id
    }
    XCTAssertEqual(uploads.count, 1, "N's upload must be planned with the reorder.", file: file, line: line)
    for upload in uploads { await editor.transport.failNextSentItem(upload, failure: .retryable) }
    let relaunched = try await relaunchAfterCloudKitStoresAnUnacknowledgedEdit(editor, file: file, line: line)
    let library = relaunched.library
    let current = try await library.checkedSnapshot(sortedBy: .manual)
    let added = try XCTUnwrap(current.snips.first(where: { $0.id == relaunched.snipID })?.attachments
      .first(where: { $0.id == AttachmentMatrixMember.n.id }), file: file, line: line)
    let storage = try await snapshot(library, relaunched.namespace)
    XCTAssertFalse(try publication(of: added.id, in: storage).metadataAccepted,
      "N must still wait for its upload.", file: file, line: line)
    let expected = original + [added]
    let undone = try await snips(restoring: expected, in: relaunched)

    try await relaunched.sync.fetchRemote(beforeApply: {
      _ = try await library.perform(.replaceAll(undone), sortedBy: .manual)
    })

    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let shown = try XCTUnwrap(local.snips.first(where: { $0.id == relaunched.snipID }),
      file: file, line: line).attachments
    XCTAssertEqual(shown.map(\.id), expected.map(\.id),
      "Fetching the unacknowledged save must keep the undone order beside N.", file: file, line: line)
    let positions = try await library.storedAttachmentReferencePositions(for: relaunched.snipID)
    XCTAssertEqual(positions, canonicalPositions(expected.map(\.id)), file: file, line: line)
    try await assertAttachmentsSettle(expected.map { (id: $0.id, fileName: $0.fileName) },
      between: relaunched, and: peer, file: file, line: line)
  }

  private func canonicalPositions(_ order: [UUID]) -> [UUID: Int] {
    Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
  }

  /// CloudKit stores the client's pending attachment edit, but Snip Snap quits before applying the
  /// result, so the relaunched client's shadows still hold the values from before the edit.
  private func relaunchAfterCloudKitStoresAnUnacknowledgedEdit(
    _ client: AttachmentClient,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws -> AttachmentClient {
    let outbound = try await client.store.pendingChanges()
    let sent = try await client.transport.send(outbound)
    XCTAssertTrue(sent.items.contains(where: { item in
      if case .saved(let record) = item {
        record.recordType == CloudAttachmentRecordCodec.metadataRecordType
      } else {
        false
      }
    }), "CloudKit must store the attachment edit before Snip Snap quits.", file: file, line: line)
    return try reopened(client)
  }

  /// The library's snips with the client's snip given back these attachments, as an undo does.
  private func snips(restoring attachments: [SnipAttachment], in client: AttachmentClient) async throws -> [Snip] {
    var snips = try await client.library.checkedSnapshot(sortedBy: .manual).snips
    let index = try XCTUnwrap(snips.firstIndex(where: { $0.id == client.snipID }), "The snip must exist.")
    snips[index].attachments = attachments
    return snips
  }

  /// Syncs both devices, then checks that they and iCloud hold these attachments in this order.
  private func assertAttachmentsSettle(
    _ expected: [(id: UUID, fileName: String)],
    between first: AttachmentClient,
    and second: AttachmentClient,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for _ in 0..<3 {
      try await first.sync.sync()
      try await second.sync.sync()
    }
    let order = try await assertSettledAttachmentOrder(Set(expected.map(\.id)), between: first, and: second,
      file: file, line: line)
    XCTAssertEqual(order, expected.map(\.id), "Both devices and iCloud must settle on this order.",
      file: file, line: line)
    for client in [first, second] {
      let local = try await client.library.checkedSnapshot(sortedBy: .manual)
      let snip = try XCTUnwrap(local.snips.first(where: { $0.id == client.snipID }), file: file, line: line)
      XCTAssertEqual(snip.attachments.map(\.fileName), expected.map(\.fileName), file: file, line: line)
      let storage = try await snapshot(client.library, client.namespace)
      for attachment in expected {
        let row = try publication(of: attachment.id, in: storage)
        XCTAssertEqual(row.metadata.fileName, attachment.fileName, file: file, line: line)
        let remote = await client.server.fullSnapshot(
          for: CloudAttachmentRecordCodec.recordID(row.metadataIdentity)
        )
        XCTAssertEqual(remote?.encryptedFields["fileName"], .string(attachment.fileName), file: file, line: line)
      }
    }
  }

  private func assertSettledAttachmentOrder(
    _ expectedIDs: Set<UUID>,
    between first: AttachmentClient,
    and second: AttachmentClient,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws -> [UUID] {
    let firstSnapshot = try await first.library.checkedSnapshot(sortedBy: .manual)
    let firstSnip = try XCTUnwrap(firstSnapshot.snips.first(where: { $0.id == first.snipID }),
      file: file, line: line)
    let order = firstSnip.attachments.map(\.id)
    XCTAssertEqual(Set(order), expectedIDs, file: file, line: line)
    for client in [first, second] {
      let local = try await client.library.checkedSnapshot(sortedBy: .manual)
      let snip = try XCTUnwrap(local.snips.first(where: { $0.id == client.snipID }), file: file, line: line)
      XCTAssertEqual(snip.attachments.map(\.id), order, file: file, line: line)
      let positions = try await client.library.storedAttachmentReferencePositions(for: client.snipID)
      XCTAssertEqual(Set(positions.keys), expectedIDs, file: file, line: line)
      XCTAssertEqual(Set(positions.values), Set(0..<expectedIDs.count),
        "Stored reference positions must be unique and contiguous.", file: file, line: line)
      let storage = try await snapshot(client.library, client.namespace)
      XCTAssertEqual(Set(storage.publications.map(\.metadata.attachmentID)), expectedIDs, file: file, line: line)
      for (position, id) in order.enumerated() {
        let row = try publication(of: id, in: storage)
        XCTAssertTrue(row.metadataAccepted, file: file, line: line)
        XCTAssertNil(row.lastFailure, file: file, line: line)
        XCTAssertEqual(positions[id], position, file: file, line: line)
        let remote = await client.server.fullSnapshot(for: CloudAttachmentRecordCodec.recordID(row.metadataIdentity))
        XCTAssertEqual(remote?.encryptedFields["position"], .int64(Int64(position)), file: file, line: line)
      }
      let next = try await client.store.pendingChanges()
      XCTAssertFalse(next.operations.contains(where: { operation in
        guard case .save(let draft) = operation else { return false }
        return draft.recordType == CloudAttachmentRecordCodec.metadataRecordType
      }), "A settled order must plan no attachment metadata save.", file: file, line: line)
    }
    return order
  }

  private func assertSyncedAttachments(
    _ expected: [(id: UUID, fileName: String)],
    in pair: DownloadedAttachmentPair,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for library in [pair.senderLibrary, pair.receiverLibrary] {
      let local = try await library.checkedSnapshot(sortedBy: .manual)
      let snip = try XCTUnwrap(local.snips.first(where: { $0.id == pair.snipID }), file: file, line: line)
      XCTAssertEqual(snip.attachments.map(\.id), expected.map { $0.id }, file: file, line: line)
      XCTAssertEqual(snip.attachments.map(\.fileName), expected.map { $0.fileName }, file: file, line: line)
      let storage = try await snapshot(library, pair.namespace)
      for (position, attachment) in expected.enumerated() {
        let row = try publication(of: attachment.id, in: storage)
        XCTAssertEqual(row.metadata.position, position, file: file, line: line)
        XCTAssertEqual(row.metadata.fileName, attachment.fileName, file: file, line: line)
        XCTAssertTrue(row.metadataAccepted, file: file, line: line)
        XCTAssertNil(row.lastFailure, file: file, line: line)
      }
    }
    let storage = try await snapshot(pair.senderLibrary, pair.namespace)
    for (position, attachment) in expected.enumerated() {
      let row = try publication(of: attachment.id, in: storage)
      let remote = await pair.server.fullSnapshot(
        for: CloudAttachmentRecordCodec.recordID(row.metadataIdentity)
      )
      XCTAssertEqual(remote?.encryptedFields["fileName"], .string(attachment.fileName), file: file, line: line)
      XCTAssertEqual(remote?.encryptedFields["position"], .int64(Int64(position)), file: file, line: line)
    }
  }

  private func editText(
    ofSnip snipID: UUID,
    to content: String,
    in library: SwiftDataSnipLibrary
  ) async throws {
    _ = try await library.perform(
      .update(
        id: snipID,
        content: content,
        attachmentURLs: nil,
        expectedUpdatedAt: nil,
        now: Date(timeIntervalSince1970: 4)
      ),
      sortedBy: .manual
    )
  }


  /// A metadata shadow that decodes like one CloudKit returned, so planned deletes keep it.
  private func metadataShadow(_ identity: CloudTextStorageIdentity) throws -> CloudRecordShadow {
    try CloudRecordShadow.archive(CKRecord(
      recordType: CloudAttachmentRecordCodec.metadataRecordType,
      recordID: CloudKitRecordMapper.recordID(for: CloudAttachmentRecordCodec.recordID(identity))
    ))
  }

  /// A payload shadow that decodes like one CloudKit returned, so its cleanup's delete keeps it.
  private func payloadShadow(_ identity: CloudTextStorageIdentity) throws -> CloudRecordShadow {
    try CloudRecordShadow.archive(CKRecord(
      recordType: CloudAttachmentRecordCodec.payloadRecordType,
      recordID: CloudKitRecordMapper.recordID(for: CloudAttachmentRecordCodec.recordID(identity))
    ))
  }

  /// Publishes two local-source attachments, removes the one at position 0, and plans the
  /// batch that deletes its metadata while the other moves to position 0 with metadata pending.
  private func makeRemovedPublishedAttachmentFixture() async throws -> (
    fixture: PendingAttachmentFixture,
    removed: CloudAttachmentPublication,
    remaining: CloudAttachmentPublication
  ) {
    let fixture = try await makePendingAttachmentFixture(names: ["removed", "remaining"])
    let pending = try await snapshot(fixture.library, fixture.namespace)
    var acceptPayloads: [CloudAttachmentTransition] = []
    for publication in pending.publications {
      let shadow = try payloadShadow(publication.metadata.payloadIdentity)
      acceptPayloads.append(.payloadAccepted(
        attachmentID: publication.metadata.attachmentID,
        expectedRevision: publication.revision,
        shadowData: shadow.data,
        systemFields: shadow.systemFields
      ))
    }
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: acceptPayloads
    )
    let payloadsAccepted = try await snapshot(fixture.library, fixture.namespace)
    var acceptMetadata: [CloudAttachmentTransition] = []
    for publication in payloadsAccepted.publications {
      let shadow = try metadataShadow(publication.metadataIdentity)
      acceptMetadata.append(.metadataAccepted(
        attachmentID: publication.metadata.attachmentID,
        expectedRevision: publication.revision,
        shadowData: shadow.data,
        systemFields: shadow.systemFields
      ))
    }
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: acceptMetadata
    )
    let published = try await snapshot(fixture.library, fixture.namespace)
    XCTAssertTrue(published.publications.allSatisfy(\.metadataAccepted))
    let removedPublished = try XCTUnwrap(published.publications.first(where: {
      $0.metadata.fileName == "removed.txt"
    }))
    let remainingPublished = try XCTUnwrap(published.publications.first(where: {
      $0.metadata.fileName == "remaining.txt"
    }))
    XCTAssertEqual(removedPublished.metadata.position, 0)
    XCTAssertEqual(remainingPublished.metadata.position, 1)
    let local = try await fixture.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: {
      $0.id == remainingPublished.metadata.snipID
    }))
    _ = try await fixture.library.perform(
      .editAttachments(
        snipID: snip.id,
        content: snip.content,
        edits: [.existing(attachmentID: remainingPublished.metadata.attachmentID)],
        expectedUpdatedAt: snip.updatedAt,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )
    let sent = try await fixture.store.pendingChanges()
    XCTAssertTrue(sent.operations.contains(where: {
      $0.id == CloudAttachmentRecordCodec.recordID(removedPublished.metadataIdentity)
    }))
    XCTAssertTrue(sent.operations.contains(where: {
      $0.id == CloudAttachmentRecordCodec.recordID(remainingPublished.metadataIdentity)
    }))
    let planned = try await snapshot(fixture.library, fixture.namespace)
    let removed = try XCTUnwrap(planned.publications.first(where: {
      $0.metadata.attachmentID == removedPublished.metadata.attachmentID
    }))
    let remaining = try XCTUnwrap(planned.publications.first(where: {
      $0.metadata.attachmentID == remainingPublished.metadata.attachmentID
    }))
    XCTAssertFalse(removed.isLocallyPresent)
    XCTAssertTrue(remaining.isLocallyPresent)
    XCTAssertEqual(remaining.metadata.position, 0)
    XCTAssertFalse(remaining.metadataAccepted)
    return (fixture, removed, remaining)
  }

  private func assertCleanupWaitsForRemappedReplacement(
    _ fixture: PendingAttachmentFixture,
    removedPayload: CloudTextStorageIdentity,
    remainingOldPayload: CloudTextStorageIdentity,
    replacedAttachmentID: UUID,
    remappedAttachmentID: UUID,
    remappedMetadataIdentity: CloudTextStorageIdentity,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let cleanupRecordID = CloudAttachmentRecordCodec.recordID(removedPayload)
    let remappedMetadataRecordID = CloudAttachmentRecordCodec.recordID(remappedMetadataIdentity)
    let remapped = try await snapshot(fixture.library, fixture.namespace)
    XCTAssertNil(remapped.publications.first(where: {
      $0.metadata.attachmentID == replacedAttachmentID
    }), "The remap must retire the replaced publication.", file: file, line: line)
    let replacement = try XCTUnwrap(remapped.publications.first(where: {
      $0.metadata.attachmentID == remappedAttachmentID
    }), "The remap must add the replacement publication.", file: file, line: line)
    XCTAssertFalse(
      replacement.metadataAccepted,
      "The replacement's metadata must start pending.",
      file: file,
      line: line
    )
    XCTAssertFalse(replacement.payloadAccepted, file: file, line: line)
    XCTAssertNotEqual(replacement.metadata.payloadIdentity, remainingOldPayload, file: file, line: line)
    XCTAssertEqual(
      remapped.cleanups.first(where: { $0.identity == remainingOldPayload })?.blockedByAttachmentID,
      remappedAttachmentID,
      file: file,
      line: line
    )
    XCTAssertEqual(
      remapped.cleanups.first(where: { $0.identity == removedPayload })?.blockedByAttachmentID,
      remappedAttachmentID,
      "The stored cleanup must wait for the remapped replacement.",
      file: file,
      line: line
    )

    let remappedBatch = try await fixture.store.pendingChanges()

    XCTAssertTrue(
      remappedBatch.operations.contains(where: {
        $0.id == CloudAttachmentRecordCodec.recordID(replacement.metadata.payloadIdentity)
      }),
      "The replacement's payload must upload first.",
      file: file,
      line: line
    )
    XCTAssertFalse(
      remappedBatch.operations.contains(where: { $0.id == remappedMetadataRecordID }),
      "The metadata must wait for the fresh payload.",
      file: file,
      line: line
    )
    let cleanupRecordIDs = [cleanupRecordID, CloudAttachmentRecordCodec.recordID(remainingOldPayload)]
    XCTAssertFalse(
      remappedBatch.operations.contains(where: { cleanupRecordIDs.contains($0.id) }),
      "The old payload must stay until the replacement's metadata is accepted.",
      file: file,
      line: line
    )
    let ready = try await snapshot(fixture.library, fixture.namespace)
    let readyReplacement = try XCTUnwrap(ready.publications.first(where: {
      $0.metadata.attachmentID == remappedAttachmentID
    }), "The replacement must still be pending after planning.", file: file, line: line)
    let payloadRecord = try payloadShadow(readyReplacement.metadata.payloadIdentity)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.payloadAccepted(
        attachmentID: remappedAttachmentID,
        expectedRevision: readyReplacement.revision,
        shadowData: payloadRecord.data,
        systemFields: payloadRecord.systemFields
      )]
    )
    let metadataBatch = try await fixture.store.pendingChanges()
    XCTAssertTrue(
      metadataBatch.operations.contains(where: { $0.id == remappedMetadataRecordID }),
      "The metadata must publish after the fresh payload.",
      file: file,
      line: line
    )
    XCTAssertFalse(
      metadataBatch.operations.contains(where: { cleanupRecordIDs.contains($0.id) }),
      file: file,
      line: line
    )
    let uploaded = try await snapshot(fixture.library, fixture.namespace)
    let uploadedReplacement = try publication(of: remappedAttachmentID, in: uploaded)
    let shadow = try metadataShadow(remappedMetadataIdentity)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.metadataAccepted(
        attachmentID: remappedAttachmentID,
        expectedRevision: uploadedReplacement.revision,
        shadowData: shadow.data,
        systemFields: shadow.systemFields
      )]
    )

    let releasedBatch = try await fixture.store.pendingChanges()

    for id in cleanupRecordIDs {
      XCTAssertTrue(
        releasedBatch.operations.contains(where: { operation in
          if case .delete(let deletedID, _) = operation { deletedID == id } else { false }
        }),
        "Accepting the replacement's metadata must release both old payloads' cleanups.",
        file: file,
        line: line
      )
    }
  }

  private func makeAvailableCacheFixture(
    named name: String
  ) async throws -> AvailableCacheFixture {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let bytes = Data("verified cache bytes".utf8)
    let source = root.appendingPathComponent("\(name).txt")
    try bytes.write(to: source)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    _ = try await library.perform(
      .add(
        content: name,
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    let namespace = namespaceValue()
    try await library.reconcileCloudAttachments(
      namespaceKey: namespace.namespaceKey,
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let storage = try await snapshot(library, namespace)
    let publication = try XCTUnwrap(storage.publications.first)
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace.namespaceKey,
      transitions: [.remoteMetadataAccepted(
        metadata: publication.metadata,
        metadataIdentity: publication.metadataIdentity,
        shadowData: Data("metadata-shadow".utf8),
        systemFields: Data()
      )]
    )
    let stagingRoot = try await library.cloudAttachmentStagingRoot(
      namespaceKey: namespace.namespaceKey
    )
    let staged = stagingRoot.appendingPathComponent("\(name)/payload")
    try FileManager.default.createDirectory(
      at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try bytes.write(to: staged)
    let cachedURL = try await library.installCloudAttachmentDownload(
      namespaceKey: namespace.namespaceKey,
      attachmentID: publication.metadata.attachmentID,
      expectedPayloadIdentity: publication.metadata.payloadIdentity,
      expectedField: CloudAttachmentRecordCodec.assetField,
      download: CloudAttachmentCacheDownload(
        payloadIdentity: publication.metadata.payloadIdentity,
        field: CloudAttachmentRecordCodec.assetField,
        fileURL: staged,
        byteCount: Int64(bytes.count),
        sha256: Data(SHA256.hash(data: bytes))
      ),
      maximumBytes: 1_024,
      now: .distantPast
    )
    return AvailableCacheFixture(
      root: root,
      bytes: bytes,
      library: library,
      namespace: namespace,
      attachmentID: publication.metadata.attachmentID,
      cachedURL: cachedURL
    )
  }


  private func makePendingAttachmentFixture(
    names: [String]
  ) async throws -> PendingAttachmentFixture {
    let seed = try await makeLocalAttachmentSeed(names: names)
    let store = CloudFullSyncPersistence(
      library: seed.library,
      namespace: seed.namespace,
      dataZone: CloudZoneID(name: "data", ownerName: "owner"),
      payloadZone: CloudZoneID(name: "payload", ownerName: "owner")
    )
    _ = try await store.pendingChanges()
    return PendingAttachmentFixture(
      root: seed.root,
      library: seed.library,
      namespace: seed.namespace,
      store: store
    )
  }

  /// Client 1 publishes one snip with two attachments from its local files. Client 2 fetches
  /// the snip, so both of its copies are remote-only, and downloads both into its cache.
  private func makeDownloadedAttachmentPair() async throws -> DownloadedAttachmentPair {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let namespace = namespaceValue()
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let server = FakeCloudServer()
    let contents = [
      (fileName: "first.txt", bytes: Data("first downloaded attachment".utf8)),
      (fileName: "second.txt", bytes: Data("second downloaded attachment".utf8)),
    ]
    let sources = try contents.map { content in
      let url = root.appendingPathComponent(content.fileName)
      try content.bytes.write(to: url)
      return url
    }
    let senderLibrary = try SwiftDataSnipLibrary(
      storeURL: root.appendingPathComponent("sender.store")
    )
    _ = try await senderLibrary.perform(
      .add(
        content: "two attachments",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: sources,
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    let added = try await senderLibrary.checkedSnapshot(sortedBy: .manual)
    let snipID = try XCTUnwrap(added.snips.first(where: { $0.content == "two attachments" })).id
    let senderStore = CloudFullSyncPersistence(
      library: senderLibrary,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    try await senderStore.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let senderTransport = FakeCloudRecordTransport(
      server: server,
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    let sender = CloudFullSyncCoordinator(
      store: senderStore,
      transport: senderTransport,
      fetchScope: .zones([dataZone])
    )
    // The first sync accepts the payloads; the second publishes the metadata that names them.
    try await sender.sync()
    try await sender.sync()
    let published = try await snapshot(senderLibrary, namespace)
    XCTAssertEqual(published.publications.count, contents.count)
    XCTAssertTrue(published.publications.allSatisfy(\.metadataAccepted))

    let receiverLibrary = try SwiftDataSnipLibrary(
      storeURL: root.appendingPathComponent("receiver.store")
    )
    let receiverStore = CloudFullSyncPersistence(
      library: receiverLibrary,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    let receiverTransport = FakeCloudRecordTransport(
      server: server,
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    let receiver = CloudFullSyncCoordinator(
      store: receiverStore,
      transport: receiverTransport,
      fetchScope: .zones([dataZone])
    )
    try await receiver.fetchRemote()
    let assetFetches = AssetFetchCountingTransport(base: receiverTransport)
    let downloads = CloudAttachmentTransferCoordinator(
      library: receiverLibrary,
      namespace: namespace,
      payloadZone: payloadZone,
      transport: assetFetches,
      maximumCacheBytes: 1_024
    )
    let received = try await receiverLibrary.checkedSnapshot(sortedBy: .manual)
    let receivedSnip = try XCTUnwrap(received.snips.first(where: { $0.id == snipID }))
    XCTAssertEqual(receivedSnip.attachments.map(\.fileName), contents.map { $0.fileName })
    let receivedStorage = try await snapshot(receiverLibrary, namespace)
    var attachments: [DownloadedPairAttachment] = []
    for (attachment, content) in zip(receivedSnip.attachments, contents) {
      let remote = try publication(of: attachment.id, in: receivedStorage)
      XCTAssertTrue(remote.metadataAccepted)
      XCTAssertNil(remote.localSourceURL)
      let cachedURL = try await downloads.download(attachmentID: attachment.id)
      XCTAssertEqual(try Data(contentsOf: cachedURL), content.bytes)
      attachments.append(DownloadedPairAttachment(
        id: attachment.id,
        fileName: content.fileName,
        bytes: content.bytes,
        metadataIdentity: remote.metadataIdentity,
        cachedURL: cachedURL
      ))
    }
    let first = try XCTUnwrap(attachments.first)
    let second = try XCTUnwrap(attachments.last)
    return DownloadedAttachmentPair(
      root: root,
      namespace: namespace,
      server: server,
      snipID: snipID,
      first: first,
      second: second,
      senderLibrary: senderLibrary,
      senderStore: senderStore,
      senderTransport: senderTransport,
      sender: sender,
      receiverLibrary: receiverLibrary,
      receiverStore: receiverStore,
      receiver: receiver,
      downloads: downloads,
      assetFetches: assetFetches
    )
  }

  /// Edits client 2's snip so it keeps only these attachments, in this order.
  private func editDownloadedAttachments(
    _ pair: DownloadedAttachmentPair,
    keeping attachmentIDs: [UUID]
  ) async throws {
    try await keepAttachments(attachmentIDs, ofSnip: pair.snipID, in: pair.receiverLibrary)
  }

  private func publication(
    of attachmentID: UUID,
    in storage: CloudAttachmentStorageSnapshot
  ) throws -> CloudAttachmentPublication {
    try XCTUnwrap(storage.publications.first(where: { $0.metadata.attachmentID == attachmentID }))
  }

  private func plansMetadataSave(
    for attachment: DownloadedPairAttachment,
    in batch: CloudOutboundBatch
  ) -> Bool {
    batch.operations.contains { operation in
      guard case .save = operation else { return false }
      return operation.id == CloudAttachmentRecordCodec.recordID(attachment.metadataIdentity)
    }
  }



  private func compatibilitySnapshot(
    in root: URL,
    sizes: [Int64]
  ) throws -> SnipLibrarySnapshot {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var attachments: [SnipAttachment] = []
    var urls: [UUID: URL] = [:]
    for (index, size) in sizes.enumerated() {
      let id = UUID()
      let fileName = "file-\(index).bin"
      let url = root.appendingPathComponent(fileName)
      _ = FileManager.default.createFile(atPath: url.path, contents: nil)
      let handle = try FileHandle(forWritingTo: url)
      try handle.truncate(atOffset: UInt64(size))
      try handle.close()
      attachments.append(SnipAttachment(
        id: id,
        fileName: fileName,
        relativePath: id.uuidString,
        contentType: "application/octet-stream",
        byteCount: size
      ))
      urls[id] = url
    }
    return SnipLibrarySnapshot(
      snips: [Snip(content: "limits", origin: .quickEntry, attachments: attachments)],
      lists: [.inbox],
      attachmentURLs: urls
    )
  }
}

private extension SwiftDataSnipLibrary {
  // Change only the imported ID so assigning the adverse ID preserves the raw position tie under test.
  func setUnpublishedAttachmentID(_ originalID: UUID, to fixedID: UUID, for snipID: UUID) throws {
    let context = Self.makeContext(container: try XCTUnwrap(container))
    let attachment = try XCTUnwrap(context.fetch(FetchDescriptor<StoredAttachmentRecord>(
      predicate: #Predicate<StoredAttachmentRecord> { $0.id == originalID }
    )).first)
    let reference = try XCTUnwrap(context.fetch(FetchDescriptor<StoredSnipAttachmentReference>(
      predicate: #Predicate<StoredSnipAttachmentReference> {
        $0.snipID == snipID && $0.attachmentID == originalID
      }
    )).first)
    attachment.id = fixedID
    reference.attachmentID = fixedID
    reference.id = StoredSnipAttachmentReference.identifier(snipID: snipID, attachmentID: fixedID)
    try context.save()
  }

  func setStoredAttachmentReferencePositions(_ positions: [UUID: Int], for snipID: UUID) throws {
    let context = Self.makeContext(container: try XCTUnwrap(container))
    let references = try context.fetch(FetchDescriptor<StoredSnipAttachmentReference>(
      predicate: #Predicate<StoredSnipAttachmentReference> { $0.snipID == snipID }
    ))
    for reference in references {
      reference.update(position: try XCTUnwrap(positions[reference.attachmentID]))
    }
    try context.save()
  }

  func storedAttachmentReferencePositions(for snipID: UUID) throws -> [UUID: Int] {
    let context = Self.makeContext(container: try XCTUnwrap(container))
    let references = try context.fetch(FetchDescriptor<StoredSnipAttachmentReference>(
      predicate: #Predicate<StoredSnipAttachmentReference> { $0.snipID == snipID }
    ))
    return Dictionary(uniqueKeysWithValues: references.map { ($0.attachmentID, $0.position) })
  }
}

private struct AttachmentClient {
  let root: URL
  let storeURL: URL
  let namespace: CloudSyncNamespace
  let server: FakeCloudServer
  let snipID: UUID
  let library: SwiftDataSnipLibrary
  let store: CloudFullSyncPersistence
  let transport: FakeCloudRecordTransport
  let sync: CloudFullSyncCoordinator
}

private struct HeldMetadataDelete {
  let client: AttachmentClient
  let published: CloudAttachmentPublication
  let snip: Snip
  let outbound: CloudOutboundBatch
  let sent: CloudSentBatch
}

private struct AvailableCacheFixture {
  let root: URL
  let bytes: Data
  let library: SwiftDataSnipLibrary
  let namespace: CloudSyncNamespace
  let attachmentID: UUID
  let cachedURL: URL
}

private struct LocalAttachmentSeed {
  let root: URL
  let storeURL: URL
  let library: SwiftDataSnipLibrary
  let namespace: CloudSyncNamespace
  let snipID: UUID
}

private struct PendingAttachmentFixture {
  let root: URL
  let library: SwiftDataSnipLibrary
  let namespace: CloudSyncNamespace
  let store: CloudFullSyncPersistence
}

private struct DownloadedAttachmentPair {
  let root: URL
  let namespace: CloudSyncNamespace
  let server: FakeCloudServer
  let snipID: UUID
  /// Published at position 0.
  let first: DownloadedPairAttachment
  /// Published at position 1.
  let second: DownloadedPairAttachment
  /// Client 1, which published from its local files.
  let senderLibrary: SwiftDataSnipLibrary
  let senderStore: CloudFullSyncPersistence
  let senderTransport: FakeCloudRecordTransport
  let sender: CloudFullSyncCoordinator
  /// Client 2, which only fetched and downloaded.
  let receiverLibrary: SwiftDataSnipLibrary
  let receiverStore: CloudFullSyncPersistence
  let receiver: CloudFullSyncCoordinator
  let downloads: CloudAttachmentTransferCoordinator
  let assetFetches: AssetFetchCountingTransport
}

private struct DownloadedPairAttachment {
  let id: UUID
  let fileName: String
  let bytes: Data
  let metadataIdentity: CloudTextStorageIdentity
  /// Where client 2's cache installed the download.
  let cachedURL: URL
}

private actor MismatchedAssetReceiptTransport: CloudRecordTransport {
  private let base: any CloudRecordTransport

  init(base: any CloudRecordTransport) {
    self.base = base
  }

  func start(state: CloudEngineStateEnvelope?) async throws {
    try await base.start(state: state)
  }

  func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch {
    try await base.fetch(scope: scope)
  }

  func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
    try await base.send(batch)
  }

  func confirmApplied(_ batchID: UUID) async throws {
    try await base.confirmApplied(batchID)
  }

  func fetchRecord(
    _ id: CloudRecordID,
    fields: Set<String>
  ) async throws -> CloudRecordSnapshot? {
    try await base.fetchRecord(id, fields: fields)
  }

  func fetchAsset(
    _ id: CloudRecordID,
    field: String,
    destination: CloudAssetDestination
  ) async throws -> CloudAssetReceipt? {
    guard let receipt = try await base.fetchAsset(id, field: field, destination: destination) else {
      return nil
    }
    return CloudAssetReceipt(
      recordID: receipt.recordID,
      field: "wrong-field",
      fileURL: receipt.fileURL,
      byteCount: receipt.byteCount,
      sha256: receipt.sha256
    )
  }
}

private actor OutsideAssetReceiptTransport: CloudRecordTransport {
  private let fileURL: URL

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  func start(state: CloudEngineStateEnvelope?) async throws {}
  func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch {
    throw CloudTransportError.invalidRecord
  }
  func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
    throw CloudTransportError.invalidRecord
  }
  func confirmApplied(_ batchID: UUID) async throws {}
  func fetchRecord(
    _ id: CloudRecordID,
    fields: Set<String>
  ) async throws -> CloudRecordSnapshot? { nil }
  func fetchAsset(
    _ id: CloudRecordID,
    field: String,
    destination: CloudAssetDestination
  ) async throws -> CloudAssetReceipt? {
    CloudAssetReceipt(
      recordID: id,
      field: field,
      fileURL: fileURL,
      byteCount: 0,
      sha256: Data()
    )
  }
}

/// Counts payload fetches, so a test can tell an open served from the cache from a download.
private actor AssetFetchCountingTransport: CloudRecordTransport {
  private let base: any CloudRecordTransport
  private(set) var count = 0

  init(base: any CloudRecordTransport) {
    self.base = base
  }

  func start(state: CloudEngineStateEnvelope?) async throws {
    try await base.start(state: state)
  }

  func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch {
    try await base.fetch(scope: scope)
  }

  func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
    try await base.send(batch)
  }

  func confirmApplied(_ batchID: UUID) async throws {
    try await base.confirmApplied(batchID)
  }

  func fetchRecord(
    _ id: CloudRecordID,
    fields: Set<String>
  ) async throws -> CloudRecordSnapshot? {
    try await base.fetchRecord(id, fields: fields)
  }

  func fetchAsset(
    _ id: CloudRecordID,
    field: String,
    destination: CloudAssetDestination
  ) async throws -> CloudAssetReceipt? {
    count += 1
    return try await base.fetchAsset(id, field: field, destination: destination)
  }
}

fileprivate protocol AttachmentTransferTestSupport {}

fileprivate extension AttachmentTransferTestSupport {
  /// One client with one snip whose attachments come from local files, enrolled but not synced.
  func makeAttachmentClient(fileNames: [String]) async throws -> AttachmentClient {
    let seed = try await makeLocalAttachmentSeed(names: fileNames)
    let client = attachmentClient(
      root: seed.root,
      storeURL: seed.storeURL,
      library: seed.library,
      namespace: seed.namespace,
      server: FakeCloudServer(),
      snipID: seed.snipID
    )
    try await client.store.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: seed.snipID),
    ])
    return client
  }

  func attachmentClient(
    root: URL,
    storeURL: URL,
    namespace: CloudSyncNamespace,
    server: FakeCloudServer,
    snipID: UUID
  ) throws -> AttachmentClient {
    attachmentClient(
      root: root,
      storeURL: storeURL,
      library: try SwiftDataSnipLibrary(storeURL: storeURL),
      namespace: namespace,
      server: server,
      snipID: snipID
    )
  }

  func attachmentClient(
    root: URL,
    storeURL: URL,
    library: SwiftDataSnipLibrary,
    namespace: CloudSyncNamespace,
    server: FakeCloudServer,
    snipID: UUID
  ) -> AttachmentClient {
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: CloudZoneID(name: "payload", ownerName: "owner")
    )
    let transport = FakeCloudRecordTransport(
      server: server,
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    return AttachmentClient(
      root: root,
      storeURL: storeURL,
      namespace: namespace,
      server: server,
      snipID: snipID,
      library: library,
      store: store,
      transport: transport,
      sync: CloudFullSyncCoordinator(store: store, transport: transport, fetchScope: .zones([dataZone]))
    )
  }

  /// Edits the snip so it keeps only these attachments, in this order, as the editor does.
  func keepAttachments(
    _ attachmentIDs: [UUID],
    ofSnip snipID: UUID,
    in library: SwiftDataSnipLibrary
  ) async throws {
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == snipID }), "The snip must exist.")
    _ = try await library.perform(
      .editAttachments(
        snipID: snipID,
        content: snip.content,
        edits: attachmentIDs.map { SnipAttachmentEdit.existing(attachmentID: $0) },
        expectedUpdatedAt: snip.updatedAt,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )
  }

  /// Renames an attachment, defaulting to the first, as a whole-library replace does.
  func renameAttachment(
    ofSnip snipID: UUID,
    attachmentID: UUID? = nil,
    to fileName: String,
    in library: SwiftDataSnipLibrary
  ) async throws {
    var snips = try await library.checkedSnapshot(sortedBy: .manual).snips
    let index = try XCTUnwrap(snips.firstIndex(where: { $0.id == snipID }), "The snip must exist.")
    let attachmentIndex: Int
    if let attachmentID {
      attachmentIndex = try XCTUnwrap(snips[index].attachments.firstIndex(where: { $0.id == attachmentID }))
    } else {
      attachmentIndex = 0
    }
    snips[index].attachments[attachmentIndex].fileName = fileName
    _ = try await library.perform(.replaceAll(snips), sortedBy: .manual)
  }

  func snapshot(
    _ library: SwiftDataSnipLibrary,
    _ namespace: CloudSyncNamespace
  ) async throws -> CloudAttachmentStorageSnapshot {
    try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
  }

  /// The values the attachment's stored shadow holds.
  func shadowMetadata(
    of attachmentID: UUID,
    in client: AttachmentClient
  ) async throws -> CloudAttachmentMetadataValue? {
    let storage = try await snapshot(client.library, client.namespace)
    guard let shadow = storage.publications.first(where: {
      $0.metadata.attachmentID == attachmentID
    })?.metadataShadowData else { return nil }
    let record = try CloudRecordShadow(data: shadow).record()
    return try CloudAttachmentRecordCodec.metadata(from: CloudKitRecordMapper.snapshot(record))
  }

  func makeLocalAttachmentSeed(names: [String]) async throws -> LocalAttachmentSeed {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sources = try names.map { name in
      let url = root.appendingPathComponent("\(name).txt")
      try Data("\(name) payload".utf8).write(to: url)
      return url
    }
    let storeURL = root.appendingPathComponent("store")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let added = try await library.perform(
      .add(
        content: "attachment fixture",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: sources,
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    return LocalAttachmentSeed(
      root: root,
      storeURL: storeURL,
      library: library,
      namespace: namespaceValue(),
      snipID: try XCTUnwrap(added.snapshot.snips.first?.id, "The fixture must save its snip.")
    )
  }

  func namespaceValue() -> CloudSyncNamespace {
    CloudSyncNamespace(
      cloudScope: "private",
      accountLineage: "account",
      generation: UUID(),
      zones: [
        CloudZoneID(name: "data", ownerName: "owner"),
        CloudZoneID(name: "payload", ownerName: "owner"),
      ]
    )
  }

  func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudAttachmentTransferTests-\(UUID().uuidString)", isDirectory: true)
  }
}

private enum AttachmentMatrixMember: UInt8, CaseIterable, Sendable {
  case a = 3, b = 1, c = 2, n = 4, m = 5, d = 6

  var id: UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, rawValue))
  }

  var fileName: String {
    switch self {
    case .a: "A.txt"
    case .b: "B.txt"
    case .c: "C.txt"
    case .n: "N.txt"
    case .m: "M.txt"
    case .d: "D.txt"
    }
  }

  /// The attachments a fixture publishes, in order. The matrix uses the first three.
  static let fixture: [Self] = [.a, .b, .c, .d]
  static let initial: [Self] = [.a, .b, .c]
  static let localOrder: [Self] = [.b, .a, .c]
  static let remoteOrder: [Self] = [.c, .a, .b]
  /// R's order with no attachment where `localOrder` puts it. `remoteOrder` keeps A in the middle,
  /// so iCloud can hold L's A beside R's other moves and still show R's whole order.
  static let remoteOrderApart: [Self] = [.c, .b, .a]
}

private enum AttachmentMatrixRole: String, CaseIterable, Sendable {
  case holder = "H", downloaded = "D"
}

private enum AttachmentMatrixLocal: String, CaseIterable, Sendable {
  case none, rename, reorder
  case addUnrecorded = "add-unrecorded"
  case addRecorded = "add-recorded"
  case removeRecorded = "remove-A-recorded"
  case inFlightReorder = "in-flight-reorder"
}

private enum AttachmentMatrixRemote: String, CaseIterable, Sendable {
  case none, rename, reorder, add
  case remove = "remove-C"
  case reorderApart = "reorder-apart"

  /// The order R keeps, if this edit reorders.
  var order: [AttachmentMatrixMember]? {
    switch self {
    case .reorder: AttachmentMatrixMember.remoteOrder
    case .reorderApart: AttachmentMatrixMember.remoteOrderApart
    case .none, .rename, .add, .remove: nil
    }
  }
}

/// When each device sends relative to its fetches.
private enum AttachmentMatrixSequence: String, Sendable {
  /// PR 2's sequence: L fetches before the send that decides the cell.
  case fetchFirst
  /// R syncs, then L sends without a fetch, so L reaches iCloud last.
  case localSendsLast = "P"
  /// L syncs, then R sends without a fetch, so R reaches iCloud last.
  case remoteSendsLast = "Q"
}

private struct AttachmentMatrixCell: Sendable, CustomStringConvertible {
  let role: AttachmentMatrixRole
  let sequence: AttachmentMatrixSequence
  let local: AttachmentMatrixLocal
  let remote: AttachmentMatrixRemote

  var description: String {
    let sequenceName = sequence == .fetchFirst ? "" : " seq=\(sequence.rawValue)"
    return "L=\(role.rawValue)\(sequenceName) local=\(local.rawValue) remote=\(remote.rawValue)"
  }

  static let all = cells(
    sequences: [.fetchFirst],
    locals: AttachmentMatrixLocal.allCases,
    remotes: [.none, .rename, .reorder, .add, .remove]
  )

  /// SM33-F2A: the last sender doesn't fetch first, so iCloud can reject part of its send.
  static let partialAcceptance = cells(
    sequences: [.localSendsLast, .remoteSendsLast],
    locals: [.rename, .reorder, .addRecorded, .removeRecorded],
    remotes: [.rename, .reorder, .add, .remove]
  )

  static let holderCells = all.filter { $0.role == .holder }
  static let downloadedCells = all.filter { $0.role == .downloaded }
  static let partialAcceptanceHolderCells = partialAcceptance.filter { $0.role == .holder }
  static let partialAcceptanceDownloadedCells = partialAcceptance.filter { $0.role == .downloaded }

  /// SM33-F2A-T1: concurrent reorders whose saves can't match by chance.
  static let reorderApart = cells(
    sequences: [.localSendsLast, .remoteSendsLast],
    locals: [.reorder],
    remotes: [.reorderApart]
  )

  static let reorderApartHolderCells = reorderApart.filter { $0.role == .holder }
  static let reorderApartDownloadedCells = reorderApart.filter { $0.role == .downloaded }

  private static func cells(
    sequences: [AttachmentMatrixSequence],
    locals: [AttachmentMatrixLocal],
    remotes: [AttachmentMatrixRemote]
  ) -> [Self] {
    AttachmentMatrixRole.allCases.flatMap { role in
      sequences.flatMap { sequence in
        locals.flatMap { local in
          remotes.map { remote in Self(role: role, sequence: sequence, local: local, remote: remote) }
        }
      }
    }
  }

  var remoteReachesICloudLast: Bool { sequence == .remoteSendsLast }

  var expectedNames: [UUID: String] {
    var names = Dictionary(uniqueKeysWithValues: AttachmentMatrixMember.initial.map { ($0.id, $0.fileName) })
    if local == .removeRecorded { names.removeValue(forKey: AttachmentMatrixMember.a.id) }
    if remote == .remove { names.removeValue(forKey: AttachmentMatrixMember.c.id) }
    if local == .addUnrecorded || local == .addRecorded {
      names[AttachmentMatrixMember.n.id] = AttachmentMatrixMember.n.fileName
    }
    if remote == .add { names[AttachmentMatrixMember.m.id] = AttachmentMatrixMember.m.fileName }
    let localName = local == .rename ? "local-B.txt" : nil
    let remoteName = remote == .rename ? "remote-B.txt" : nil
    if let name = remoteReachesICloudLast ? remoteName ?? localName : localName ?? remoteName {
      names[AttachmentMatrixMember.b.id] = name
    }
    return names
  }

  var expectedSharedOrder: [UUID] {
    let localOrder = local == .reorder || local == .inFlightReorder ? AttachmentMatrixMember.localOrder : nil
    let remoteOrder = remote.order
    let winner = remoteReachesICloudLast ? remoteOrder ?? localOrder : localOrder ?? remoteOrder
    return shared(winner ?? AttachmentMatrixMember.initial)
  }

  /// The relative orders of the shared attachments that some device chose: the starting order,
  /// L's, and R's.
  var chosenSharedOrders: [[UUID]] {
    [
      AttachmentMatrixMember.initial,
      local == .reorder ? AttachmentMatrixMember.localOrder : AttachmentMatrixMember.initial,
      remote.order ?? AttachmentMatrixMember.initial,
    ].map(shared)
  }

  var mainFloorSharedOrder: [UUID]? {
    guard sequence == .fetchFirst else { return nil }
    switch (role, local, remote) {
    case (.holder, .reorder, .add), (.holder, .inFlightReorder, .add):
      return AttachmentMatrixMember.localOrder.map(\.id)
    case (.downloaded, .addRecorded, .reorder):
      return AttachmentMatrixMember.remoteOrder.map(\.id)
    case (.downloaded, .removeRecorded, .reorder):
      return [AttachmentMatrixMember.c.id, AttachmentMatrixMember.b.id]
    default:
      return nil
    }
  }

  var mainFloorNames: [UUID: String] {
    if sequence == .fetchFirst && role == .downloaded && local == .removeRecorded && remote == .rename {
      return [AttachmentMatrixMember.b.id: "remote-B.txt"]
    }
    return [:]
  }

  private func shared(_ order: [AttachmentMatrixMember]) -> [UUID] {
    order.map(\.id).filter { expectedNames[$0] != nil }
  }
}

private struct AttachmentEditClients {
  let holder: AttachmentClient
  let downloaded: AttachmentClient

  func devices(localRole role: AttachmentMatrixRole) -> (local: AttachmentClient, remote: AttachmentClient) {
    role == .holder ? (holder, downloaded) : (downloaded, holder)
  }
}

fileprivate extension AttachmentTransferTestSupport {
  func makeAttachmentEditHolder(attachmentCount: Int) async throws -> AttachmentClient {
    let members = Array(AttachmentMatrixMember.fixture.prefix(attachmentCount))
    let holder = try await makeAttachmentClient(fileNames: members.map { String($0.fileName.dropLast(4)) })
    var snips = try await holder.library.checkedSnapshot(sortedBy: .manual).snips
    let index = try XCTUnwrap(snips.firstIndex(where: { $0.id == holder.snipID }))
    snips[index].attachments = zip(members, snips[index].attachments).map { member, attachment in
      SnipAttachment(id: member.id, fileName: member.fileName, relativePath: attachment.relativePath,
        contentType: "public.plain-text", byteCount: attachment.byteCount)
    }
    _ = try await holder.library.perform(.replaceAll(snips), sortedBy: .manual)
    try await holder.sync.sync()
    try await holder.sync.sync()
    return holder
  }

  func makeAttachmentEditClients(attachmentCount: Int = 3) async throws -> AttachmentEditClients {
    let holder = try await makeAttachmentEditHolder(attachmentCount: attachmentCount)
    let downloaded = try attachmentClient(root: holder.root,
      storeURL: holder.root.appendingPathComponent("downloaded.store"),
      namespace: holder.namespace, server: holder.server, snipID: holder.snipID)
    try await downloaded.sync.fetchRemote()
    let downloads = CloudAttachmentTransferCoordinator(library: downloaded.library,
      namespace: holder.namespace, payloadZone: CloudZoneID(name: "payload", ownerName: "owner"),
      transport: downloaded.transport, maximumCacheBytes: 1_024)
    for member in AttachmentMatrixMember.fixture.prefix(attachmentCount) {
      _ = try await downloads.download(attachmentID: member.id)
    }
    return AttachmentEditClients(holder: holder, downloaded: downloaded)
  }

  func appendAttachment(_ member: AttachmentMatrixMember, to client: AttachmentClient) async throws {
    let local = try await client.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == client.snipID }))
    let source = client.root.appendingPathComponent(member.fileName)
    try Data("\(member.fileName) payload".utf8).write(to: source)
    let update = try await client.library.perform(.editAttachments(
      snipID: client.snipID, content: snip.content,
      edits: snip.attachments.map { .existing(attachmentID: $0.id) } + [.added(sourceURL: source)],
      expectedUpdatedAt: snip.updatedAt, now: Date(timeIntervalSince1970: 3)
    ), sortedBy: .manual)
    var snips = update.snapshot.snips
    let index = try XCTUnwrap(snips.firstIndex(where: { $0.id == client.snipID }))
    let addedIndex = try XCTUnwrap(snips[index].attachments.firstIndex(where: { $0.fileName == member.fileName }))
    let added = snips[index].attachments[addedIndex]
    snips[index].attachments[addedIndex] = SnipAttachment(id: member.id, fileName: member.fileName,
      relativePath: added.relativePath, contentType: "public.plain-text", byteCount: added.byteCount)
    _ = try await client.library.perform(.replaceAll(snips), sortedBy: .manual)
  }
}

/// Where both devices and iCloud left a snip's attachments.
private struct AttachmentSettlement: Equatable, CustomTestStringConvertible {
  var server: [UUID]
  var holder: [UUID]
  var downloaded: [UUID]
  /// Stored and iCloud positions run 0 to n−1 in order, every present attachment is
  /// acknowledged without a failure, and neither device plans a metadata save.
  var isCompactAcknowledgedAndQuiet: Bool

  static func agreed(on order: [AttachmentMatrixMember]) -> Self {
    let ids = order.map(\.id)
    return Self(server: ids, holder: ids, downloaded: ids, isCompactAcknowledgedAndQuiet: true)
  }

  static func label(_ id: UUID) -> String {
    AttachmentMatrixMember.allCases.first { $0.id == id }.map { String($0.fileName.prefix(1)) }
      ?? "[\(id.uuidString.prefix(8))]"
  }

  var testDescription: String {
    let orders = [("server", server), ("H", holder), ("D", downloaded)]
      .map { "\($0)=\($1.map(Self.label).joined())" }
    return (orders + ["settled=\(isCompactAcknowledgedAndQuiet)"]).joined(separator: " ")
  }
}

@Suite(.serialized)
private struct AttachmentEditInvariantMatrixTests: AttachmentTransferTestSupport {
  @Test(arguments: AttachmentMatrixCell.holderCells)
  func testAttachmentEditInvariantMatrixWithLocalFiles(_ cell: AttachmentMatrixCell) async {
    await run(cell)
  }

  @Test(arguments: AttachmentMatrixCell.downloadedCells)
  func testAttachmentEditInvariantMatrixWithDownloadsOnly(_ cell: AttachmentMatrixCell) async {
    await run(cell)
  }

  @Test(arguments: AttachmentMatrixCell.partialAcceptanceHolderCells)
  func testPartiallyAcceptedAttachmentEditMatrixWithLocalFiles(_ cell: AttachmentMatrixCell) async {
    await run(cell)
  }

  @Test(arguments: AttachmentMatrixCell.partialAcceptanceDownloadedCells)
  func testPartiallyAcceptedAttachmentEditMatrixWithDownloadsOnly(_ cell: AttachmentMatrixCell) async {
    await run(cell)
  }

  @Test(arguments: AttachmentMatrixCell.reorderApartHolderCells)
  func testConcurrentReordersApartMatrixWithLocalFiles(_ cell: AttachmentMatrixCell) async {
    await run(cell)
  }

  @Test(arguments: AttachmentMatrixCell.reorderApartDownloadedCells)
  func testConcurrentReordersApartMatrixWithDownloadsOnly(_ cell: AttachmentMatrixCell) async {
    await run(cell)
  }

  /// SM33 P1 (Adv-F1, Primary-1): R's reorder lands first, then L sends its own without a fetch.
  /// L reaches iCloud last, so its whole order wins.
  @Test(arguments: AttachmentMatrixRole.allCases)
  func testConcurrentReordersSentWithoutAFetchKeepTheLastSendersOrder(
    _ role: AttachmentMatrixRole
  ) async throws {
    let clients = try await makeAttachmentEditClients()
    defer { try? FileManager.default.removeItem(at: clients.holder.root) }
    let (local, remote) = clients.devices(localRole: role)
    try await keepAttachments(AttachmentMatrixMember.remoteOrder.map(\.id), ofSnip: remote.snipID, in: remote.library)
    try await remote.sync.sync()
    try await keepAttachments(AttachmentMatrixMember.localOrder.map(\.id), ofSnip: local.snipID, in: local.library)

    try await local.sync.sendPendingUntilSettled()
    try await settle(lastSender: local, other: remote, local: local, remote: remote)

    let settled = try await settlement(of: AttachmentMatrixMember.initial, in: clients)
    #expect(settled == .agreed(on: AttachmentMatrixMember.localOrder), "L=\(role.rawValue)")
  }

  /// SM33 D7's same-batch variant: L's reorder lands first, then R sends its own without a fetch.
  /// iCloud takes R's save of the one member L left in place and rejects the others. R reaches
  /// iCloud last, so its whole order wins.
  @Test(arguments: AttachmentMatrixRole.allCases)
  func testAReorderResentWithoutAFetchAfterTheOtherOrderLandsKeepsItsOrder(
    _ role: AttachmentMatrixRole
  ) async throws {
    let clients = try await makeAttachmentEditClients()
    defer { try? FileManager.default.removeItem(at: clients.holder.root) }
    let (local, remote) = clients.devices(localRole: role)
    try await keepAttachments(AttachmentMatrixMember.localOrder.map(\.id), ofSnip: local.snipID, in: local.library)
    try await local.sync.sync()
    try await keepAttachments(AttachmentMatrixMember.remoteOrder.map(\.id), ofSnip: remote.snipID, in: remote.library)

    try await remote.sync.sendPendingUntilSettled()
    try await settle(lastSender: remote, other: local, local: local, remote: remote)

    let settled = try await settlement(of: AttachmentMatrixMember.initial, in: clients)
    #expect(settled == .agreed(on: AttachmentMatrixMember.remoteOrder), "L=\(role.rawValue)")
  }

  /// SM33-F2A-T1: the same-batch variant where R moves every attachment L left in place and none
  /// to where L put it. iCloud takes R's C0 and rejects its A2, and no rejected record matches R's
  /// row by chance. R reaches iCloud last, so its whole order wins.
  @Test(arguments: AttachmentMatrixRole.allCases)
  func testAReorderApartResentWithoutAFetchAfterTheOtherOrderLandsKeepsItsOrder(
    _ role: AttachmentMatrixRole
  ) async throws {
    let clients = try await makeAttachmentEditClients()
    defer { try? FileManager.default.removeItem(at: clients.holder.root) }
    let (local, remote) = clients.devices(localRole: role)
    try await keepAttachments(AttachmentMatrixMember.localOrder.map(\.id), ofSnip: local.snipID, in: local.library)
    try await local.sync.sync()
    try await keepAttachments(AttachmentMatrixMember.remoteOrderApart.map(\.id), ofSnip: remote.snipID,
      in: remote.library)

    try await remote.sync.sendPendingUntilSettled()
    try await settle(lastSender: remote, other: local, local: local, remote: remote)

    let settled = try await settlement(of: AttachmentMatrixMember.initial, in: clients)
    #expect(settled == .agreed(on: AttachmentMatrixMember.remoteOrderApart), "L=\(role.rawValue)")
  }

  /// L swaps A and B, and R swaps C and D. R's swap lands first, then L sends without a fetch.
  /// The swaps save different records but edit one order, so L's whole order wins.
  @Test(arguments: AttachmentMatrixRole.allCases)
  func testDisjointSwapsOnFourAttachmentsKeepOneWholeOrder(_ role: AttachmentMatrixRole) async throws {
    let clients = try await makeAttachmentEditClients(attachmentCount: 4)
    defer { try? FileManager.default.removeItem(at: clients.holder.root) }
    let (local, remote) = clients.devices(localRole: role)
    let localOrder: [AttachmentMatrixMember] = [.b, .a, .c, .d]
    let remoteOrder: [AttachmentMatrixMember] = [.a, .b, .d, .c]
    try await keepAttachments(remoteOrder.map(\.id), ofSnip: remote.snipID, in: remote.library)
    try await remote.sync.sync()
    try await keepAttachments(localOrder.map(\.id), ofSnip: local.snipID, in: local.library)

    try await local.sync.sendPendingUntilSettled()
    try await settle(lastSender: local, other: remote, local: local, remote: remote)

    let settled = try await settlement(of: AttachmentMatrixMember.fixture, in: clients)
    #expect(settled == .agreed(on: localOrder), "L=\(role.rawValue)")
  }

  @Test(arguments: [false, true])
  func testSparseAttachmentRetryAfterPlanningKeepsMainRecoveryAndCanonicalPositions(
    acknowledgedBeforeRetry: Bool
  ) async throws {
    let scenario = "sparse L=D B=\(acknowledgedBeforeRetry ? "acknowledged" : "unsent")"
    let holder = try await makeAttachmentEditHolder(attachmentCount: 2)
    defer { try? FileManager.default.removeItem(at: holder.root) }
    let receiver = try attachmentClient(root: holder.root,
      storeURL: holder.root.appendingPathComponent("sparse.store"), namespace: holder.namespace,
      server: holder.server, snipID: holder.snipID)
    let a = AttachmentMatrixMember.a.id
    let b = AttachmentMatrixMember.b.id
    await receiver.transport.failNextFetchedItem(metadataID(.a), failure: .retryable)

    try await receiver.sync.fetchRemote()

    // The final A,B checks carry R3-1. These pin B's stored position as local order, then the
    // row planning writes: B waits at 0 against the B1 record just fetched.
    let partial = try await receiver.library.storedAttachmentReferencePositions(for: holder.snipID)
    #expect(partial == [b: 0], "\(scenario) partial fetch stores B at local index 0")
    let plan = try await receiver.store.pendingChanges()
    #expect(plan.operations.contains(where: { operation in
      guard case .save(let draft) = operation else { return false }
      return draft.id == metadataID(.b) && draft.encryptedFields["position"] == .int64(0)
    }), "\(scenario) the partial plan records B0")
    let plannedRow = try await snapshot(receiver.library, receiver.namespace).publications
      .first(where: { $0.metadata.attachmentID == b })
    #expect(plannedRow?.metadata.position == 0 && plannedRow?.metadataAccepted == false,
      "\(scenario) planning records B's row pending at 0")
    let plannedBase = try await shadowMetadata(of: b, in: receiver)
    #expect(plannedBase?.position == 1, "\(scenario) B's base stays the fetched B1")
    if acknowledgedBeforeRetry { try await receiver.sync.sendPending() }

    try await receiver.sync.fetchRemote()
    try await receiver.sync.sendPending()
    for _ in 0..<2 { try await receiver.sync.sync() }

    var serverPositions: [UUID: Int] = [:]
    var serverNames: [UUID: String] = [:]
    var serverTypes: [UUID: String] = [:]
    for member in AttachmentMatrixMember.initial.prefix(2) {
      let fetched = await holder.server.fullSnapshot(for: metadataID(member))
      let record = try #require(fetched, "\(scenario) server keeps \(member.fileName)")
      if case .int64(let position)? = record.encryptedFields["position"] {
        serverPositions[member.id] = Int(position)
      }
      if case .string(let name)? = record.encryptedFields["fileName"] { serverNames[member.id] = name }
      if case .string(let type)? = record.encryptedFields["contentType"] { serverTypes[member.id] = type }
    }
    let serverOrder = serverPositions.keys.sorted {
      if serverPositions[$0] != serverPositions[$1] { return serverPositions[$0, default: 0] < serverPositions[$1, default: 0] }
      return $0.uuidString < $1.uuidString
    }
    let snapshot = try await receiver.library.checkedSnapshot(sortedBy: .manual)
    let snip = try #require(snapshot.snips.first(where: { $0.id == holder.snipID }), "\(scenario) receiver keeps snip")
    #expect(snip.attachments.map(\.id) == serverOrder, "\(scenario) receiver agrees with server order")
    #expect(snip.attachments.reduce(into: [UUID: String]()) { $0[$1.id] = $1.fileName } == serverNames,
      "\(scenario) receiver agrees with server names")
    #expect(snip.attachments.reduce(into: [UUID: String]()) { $0[$1.id] = $1.contentType ?? "<nil>" } == serverTypes,
      "\(scenario) receiver agrees with server types")
    let positions = try await receiver.library.storedAttachmentReferencePositions(for: holder.snipID)
    #expect(Set(positions.keys) == Set([a, b]), "\(scenario) receiver keeps both attachments")
    #expect(positions.values.sorted() == [0, 1], "\(scenario) raw positions are a permutation")
    #expect(positions == serverPositions, "\(scenario) raw positions equal the server's")
    if !acknowledgedBeforeRetry {
      #expect(serverOrder == [a, b], "\(scenario) recovers main's A,B order")
      #expect(positions == [a: 0, b: 1], "\(scenario) recovers main's coordinates")
    }
    let next = try await receiver.store.pendingChanges()
    #expect(!next.operations.contains(where: { operation in
      guard case .save(let draft) = operation else { return false }
      return draft.recordType == CloudAttachmentRecordCodec.metadataRecordType
    }), "\(scenario) next plan saves no attachment metadata")
  }

  private func run(_ cell: AttachmentMatrixCell) async {
    var log = "result=FAIL server=[] H=[] D=[]"
    defer { print("MATRIX role=\(cell) \(log)") }
    do {
      let clients = try await makeAttachmentEditClients()
      defer { try? FileManager.default.removeItem(at: clients.holder.root) }
      let (local, remote) = clients.devices(localRole: cell.role)
      var stepFailures: [String] = []
      switch cell.sequence {
      case .fetchFirst:
        try await applyLocal(cell.local, to: local)
        try await applyRemote(cell.remote, to: remote)
        try await remote.sync.sync()
        try await local.sync.sync()
        try await remote.sync.sync()
      case .localSendsLast:
        try await applyLocal(cell.local, to: local)
        _ = try await local.store.pendingChanges()
        try await applyRemote(cell.remote, to: remote)
        try await remote.sync.sync()
        stepFailures += await unchosenSharedOrder(cell, after: "R syncs", in: clients)
        try await local.sync.sendPendingUntilSettled()
        stepFailures += await unchosenSharedOrder(cell, after: "L sends without a fetch", in: clients)
        try await local.sync.sync()
        stepFailures += await unchosenSharedOrder(cell, after: "L syncs", in: clients)
        try await remote.sync.sync()
        stepFailures += await unchosenSharedOrder(cell, after: "R syncs again", in: clients)
      case .remoteSendsLast:
        try await applyLocal(cell.local, to: local)
        try await local.sync.sync()
        stepFailures += await unchosenSharedOrder(cell, after: "L syncs", in: clients)
        try await applyRemote(cell.remote, to: remote)
        try await remote.sync.sendPendingUntilSettled()
        stepFailures += await unchosenSharedOrder(cell, after: "R sends without a fetch", in: clients)
        try await remote.sync.sync()
        stepFailures += await unchosenSharedOrder(cell, after: "R syncs", in: clients)
        try await local.sync.sync()
        stepFailures += await unchosenSharedOrder(cell, after: "L syncs again", in: clients)
      }
      for pass in 1...2 {
        try await local.sync.sync()
        if cell.sequence != .fetchFirst {
          stepFailures += await unchosenSharedOrder(cell, after: "pass \(pass) L syncs", in: clients)
        }
        try await remote.sync.sync()
        if cell.sequence != .fetchFirst {
          stepFailures += await unchosenSharedOrder(cell, after: "pass \(pass) R syncs", in: clients)
        }
      }
      log = try await checkInvariants(cell, clients: clients, stepFailures: stepFailures)
    } catch {
      Issue.record("\(cell) threw: \(error)")
      log += " error=\(String(reflecting: String(describing: error)))"
    }
  }

  private func applyLocal(_ change: AttachmentMatrixLocal, to client: AttachmentClient) async throws {
    switch change {
    case .none: break
    case .rename:
      try await renameAttachment(ofSnip: client.snipID, attachmentID: AttachmentMatrixMember.b.id,
        to: "local-B.txt", in: client.library)
    case .reorder, .inFlightReorder:
      try await keepAttachments(AttachmentMatrixMember.localOrder.map(\.id), ofSnip: client.snipID, in: client.library)
      if change == .inFlightReorder {
        _ = try await client.store.pendingChanges()
        for member in [AttachmentMatrixMember.a, .b] {
          await client.transport.failNextSentItem(metadataID(member), failure: .retryable)
        }
        try await client.sync.sendPending()
      }
    case .addUnrecorded, .addRecorded:
      try await appendAttachment(.n, to: client)
      if change == .addRecorded { _ = try await client.store.pendingChanges() }
    case .removeRecorded:
      try await keepAttachments([AttachmentMatrixMember.b.id, AttachmentMatrixMember.c.id],
        ofSnip: client.snipID, in: client.library)
      _ = try await client.store.pendingChanges()
    }
  }

  private func applyRemote(_ change: AttachmentMatrixRemote, to client: AttachmentClient) async throws {
    switch change {
    case .none: break
    case .rename:
      try await renameAttachment(ofSnip: client.snipID, attachmentID: AttachmentMatrixMember.b.id,
        to: "remote-B.txt", in: client.library)
    case .reorder:
      try await keepAttachments(AttachmentMatrixMember.remoteOrder.map(\.id), ofSnip: client.snipID, in: client.library)
    case .reorderApart:
      try await keepAttachments(AttachmentMatrixMember.remoteOrderApart.map(\.id), ofSnip: client.snipID,
        in: client.library)
    case .add:
      try await appendAttachment(.m, to: client)
    case .remove:
      try await keepAttachments([AttachmentMatrixMember.a.id, AttachmentMatrixMember.b.id],
        ofSnip: client.snipID, in: client.library)
      _ = try await client.store.pendingChanges()
    }
  }

  private func metadataID(_ member: AttachmentMatrixMember) -> CloudRecordID {
    CloudAttachmentRecordCodec.recordID(CloudTextStorageIdentity(zoneName: "data", ownerName: "owner",
      recordName: "a-\(member.id.uuidString.lowercased())"))
  }

  /// Syncs the last sender, then the other device, then L and R twice.
  private func settle(
    lastSender: AttachmentClient,
    other: AttachmentClient,
    local: AttachmentClient,
    remote: AttachmentClient
  ) async throws {
    try await lastSender.sync.sync()
    try await other.sync.sync()
    for _ in 0..<2 {
      try await local.sync.sync()
      try await remote.sync.sync()
    }
  }

  /// SM33-F2A: after every step, iCloud's relative order of the shared attachments must be one a
  /// device chose. Returns the failure, if any.
  private func unchosenSharedOrder(
    _ cell: AttachmentMatrixCell,
    after step: String,
    in clients: AttachmentEditClients
  ) async -> [String] {
    var positions: [UUID: Int] = [:]
    for member in AttachmentMatrixMember.initial where cell.expectedNames[member.id] != nil {
      let record = await clients.holder.server.fullSnapshot(for: metadataID(member))
      if case .int64(let position)? = record?.encryptedFields["position"] { positions[member.id] = Int(position) }
    }
    let order = sorted(positions)
    let chosen = cell.chosenSharedOrders.map { $0.filter { positions[$0] != nil } }
    guard !chosen.contains(order) else { return [] }
    let failure = "after \(step), iCloud's shared order \(labels(order)) is one no device chose"
    Issue.record("\(cell) \(failure)")
    return [failure]
  }

  /// Where both devices and iCloud left these members.
  private func settlement(
    of members: [AttachmentMatrixMember],
    in clients: AttachmentEditClients
  ) async throws -> AttachmentSettlement {
    var serverPositions: [UUID: Int] = [:]
    for member in members {
      let record = await clients.holder.server.fullSnapshot(for: metadataID(member))
      if case .int64(let position)? = record?.encryptedFields["position"] { serverPositions[member.id] = Int(position) }
    }
    let server = sorted(serverPositions)
    var isSettled = serverPositions == compactPositions(server)
    var orders: [[UUID]] = []
    for client in [clients.holder, clients.downloaded] {
      let local = try await client.library.checkedSnapshot(sortedBy: .manual)
      let order = local.snips.first(where: { $0.id == client.snipID })?.attachments.map(\.id) ?? []
      orders.append(order)
      let positions = try await client.library.storedAttachmentReferencePositions(for: client.snipID)
      let storage = try await snapshot(client.library, client.namespace)
      let next = try await client.store.pendingChanges()
      isSettled = isSettled && positions == compactPositions(order)
        && storage.publications.filter(\.isLocallyPresent).allSatisfy { $0.metadataAccepted && $0.lastFailure == nil }
        && !next.operations.contains(where: { operation in
          guard case .save(let draft) = operation else { return false }
          return draft.recordType == CloudAttachmentRecordCodec.metadataRecordType
        })
    }
    return AttachmentSettlement(server: server, holder: orders[0], downloaded: orders[1],
      isCompactAcknowledgedAndQuiet: isSettled)
  }

  private func sorted(_ positions: [UUID: Int]) -> [UUID] {
    positions.keys.sorted {
      (positions[$0, default: 0], $0.uuidString) < (positions[$1, default: 0], $1.uuidString)
    }
  }

  private func compactPositions(_ order: [UUID]) -> [UUID: Int] {
    Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
  }

  private func labels(_ order: [UUID]) -> String {
    order.map(AttachmentSettlement.label).joined()
  }

  private func checkInvariants(
    _ cell: AttachmentMatrixCell,
    clients: AttachmentEditClients,
    stepFailures: [String]
  ) async throws -> String {
    let expectedNames = cell.expectedNames
    let expectedIDs = Set(expectedNames.keys)
    let expectedTypes = expectedNames.mapValues { _ in "public.plain-text" }
    let sharedIDs = Set(AttachmentMatrixMember.initial.map(\.id)).intersection(expectedIDs)
    let types = await clients.holder.server.storedRecordTypes(in: CloudZoneID(name: "data", ownerName: "owner"))
    var failures = stepFailures
    func check(_ condition: Bool, _ message: String) {
      #expect(condition, "\(cell) \(message)")
      if !condition { failures.append(message) }
    }
    check(types.filter { $0 == CloudAttachmentRecordCodec.metadataRecordType }.count == expectedIDs.count,
      "server membership count")
    var serverPositions: [UUID: Int] = [:]
    var serverNames: [UUID: String] = [:]
    var serverTypes: [UUID: String] = [:]
    for member in AttachmentMatrixMember.allCases {
      let record = await clients.holder.server.fullSnapshot(for: metadataID(member))
      if expectedNames[member.id] == nil {
        check(record == nil, "absent server member \(member.fileName)")
        continue
      }
      check(record != nil, "server has member \(member.fileName)")
      guard let present = record else { continue }
      if case .int64(let position)? = present.encryptedFields["position"] {
        serverPositions[member.id] = Int(position)
      } else { check(false, "server has position for \(member.fileName)") }
      if case .string(let name)? = present.encryptedFields["fileName"] { serverNames[member.id] = name }
      if case .string(let type)? = present.encryptedFields["contentType"] { serverTypes[member.id] = type }
    }
    check(serverNames == expectedNames, "server names follow field winners")
    check(serverTypes == expectedTypes, "server types")
    let serverOrder = serverPositions.keys.sorted {
      if serverPositions[$0] != serverPositions[$1] { return serverPositions[$0, default: 0] < serverPositions[$1, default: 0] }
      return $0.uuidString < $1.uuidString
    }
    let serverSharedOrder = serverOrder.filter { sharedIDs.contains($0) }
    check(serverSharedOrder == cell.expectedSharedOrder, "server shared order follows the winner")
    if let mainOrder = cell.mainFloorSharedOrder {
      check(serverSharedOrder == mainOrder, "server keeps the reorder retained by main c42d47d5")
    }
    for (id, name) in cell.mainFloorNames {
      check(serverNames[id] == name, "server keeps the rename retained by main c42d47d5")
    }
    var deviceLogs: [String] = []
    for (role, client) in [("H", clients.holder), ("D", clients.downloaded)] {
      let snapshot = try await client.library.checkedSnapshot(sortedBy: .manual)
      let snip = snapshot.snips.first(where: { $0.id == client.snipID })
      check(snip != nil, "\(role) has snip")
      let attachments = snip?.attachments ?? []
      let order = attachments.map(\.id)
      check(Set(order) == expectedIDs && order.count == expectedIDs.count, "\(role) membership")
      check(order == serverOrder, "\(role) agrees with server order")
      let sharedOrder = order.filter { sharedIDs.contains($0) }
      check(sharedOrder == cell.expectedSharedOrder, "\(role) shared order follows the winner")
      let names = attachments.reduce(into: [UUID: String]()) { $0[$1.id] = $1.fileName }
      let contentTypes = attachments.reduce(into: [UUID: String]()) { $0[$1.id] = $1.contentType ?? "<nil>" }
      check(names == expectedNames, "\(role) names follow the winner")
      check(names == serverNames, "\(role) agrees with server names")
      check(contentTypes == expectedTypes && contentTypes == serverTypes, "\(role) types")
      if let mainOrder = cell.mainFloorSharedOrder {
        check(sharedOrder == mainOrder, "\(role) keeps the reorder retained by main c42d47d5")
      }
      for (id, name) in cell.mainFloorNames {
        check(names[id] == name, "\(role) keeps the rename retained by main c42d47d5")
      }
      let positions = try await client.library.storedAttachmentReferencePositions(for: client.snipID)
      check(Set(positions.keys) == expectedIDs, "\(role) stored membership")
      check(positions.values.sorted() == Array(0..<expectedIDs.count), "\(role) positions are a permutation")
      check(positions == serverPositions, "\(role) stored positions agree with server")
      deviceLogs.append("\(role)=\(format(order: order, positions: positions, names: names, types: contentTypes))")
    }
    for (role, client) in [("H", clients.holder), ("D", clients.downloaded)] {
      let next = try await client.store.pendingChanges()
      check(!next.operations.contains(where: { operation in
        guard case .save(let draft) = operation else { return false }
        return draft.recordType == CloudAttachmentRecordCodec.metadataRecordType
      }), "\(role) quiet after settlement")
    }
    let result = failures.isEmpty ? "PASS" : "FAIL"
    let server = format(order: serverOrder, positions: serverPositions, names: serverNames, types: serverTypes)
    return "result=\(result) server=\(server) \(deviceLogs.joined(separator: " ")) failures=\(String(reflecting: failures.joined(separator: "; ")))"
  }

  private func format(order: [UUID], positions: [UUID: Int], names: [UUID: String], types: [UUID: String]) -> String {
    let extraIDs = Set(positions.keys).union(names.keys).subtracting(order).sorted { $0.uuidString < $1.uuidString }
    let entries = (order + extraIDs).map { id in
      let member = AttachmentMatrixMember.allCases.first { $0.id == id }
      let label = member.map { String($0.fileName.prefix(1)) } ?? id.uuidString
      let position = positions[id].map(String.init) ?? "missing"
      let name = String(reflecting: names[id] ?? "<missing>")
      return "\(label):\(position):\(name):\(types[id] ?? "<missing>")"
    }
    return "[\(entries.joined(separator: ","))]"
  }
}
