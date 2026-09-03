import CryptoKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

@testable import SnipSnapCloud

final class CloudAttachmentTransferTests: XCTestCase {
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
      transport: FakeCloudRecordTransport(server: server, namespace: namespace),
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
    let receiverTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
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
    let offline = FakeCloudRecordTransport(server: server, namespace: namespace)
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
      transport: FakeCloudRecordTransport(server: server, namespace: namespace),
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
    let initial = try await snapshot(fixture.library, fixture.namespace)
    let publication = try XCTUnwrap(initial.publications.first)
    let payloadID = CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity)
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(server: server, namespace: fixture.namespace)
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

    try await coordinator.sendPending()
    try await coordinator.sendPending()

    let settled = try await snapshot(fixture.library, fixture.namespace)
    XCTAssertTrue(try XCTUnwrap(settled.publications.first).metadataAccepted)
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
      transport: FakeCloudRecordTransport(server: server, namespace: namespace),
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
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
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
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
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
    XCTAssertEqual(replacement.metadata.payloadIdentity, payloadIdentity)
    XCTAssertTrue(replacement.payloadAccepted)
    XCTAssertFalse(replacement.metadataAccepted)
    let domain = try await library.checkedSnapshot(sortedBy: .manual)
    let domainSnip = try XCTUnwrap(domain.snips.first(where: { $0.id == snipID }))
    XCTAssertFalse(domainSnip.attachments.contains(where: { $0.id == oldAttachmentID }))
    XCTAssertTrue(domainSnip.attachments.contains(where: {
      $0.id == replacement.metadata.attachmentID
    }))

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
    XCTAssertNotNil(newMetadata)
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
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
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
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
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
    let automaticResult = try await CloudFullRecordCollectionSyncDriver.automaticSentResult(
      store: store
    )
    XCTAssertEqual(automaticResult, .noChange)
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
      let transport = FakeCloudRecordTransport(server: server, namespace: fixture.namespace)
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
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
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
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
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
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
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
      let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
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
      transport: FakeCloudRecordTransport(server: server, namespace: namespace),
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
    let transport = FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
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
    let reader = FakeCloudRecordTransport(server: server, namespace: namespace)
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
      transport: FakeCloudRecordTransport(server: server, namespace: namespace),
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
      transport: FakeCloudRecordTransport(server: server, namespace: namespace),
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

  func testCacheInstallRejectsOversizeBeforeConsumingStagedFile() async throws {
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
      _ = try await library.installCloudAttachmentCacheFile(
        namespaceKey: namespace.namespaceKey,
        attachmentID: publication.metadata.attachmentID,
        expectedPayloadIdentity: publication.metadata.payloadIdentity,
        stagedURL: staged,
        expectedByteCount: Int64(bytes.count),
        expectedSHA256: Data(SHA256.hash(data: bytes)),
        maximumBytes: Int64(bytes.count - 1),
        now: .distantPast
      )
      XCTFail("An oversize file must not enter the cache.")
    } catch {
      XCTAssertEqual(error as? CloudAttachmentStorageError, .sizeMismatch)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
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
      _ = try await library.installCloudAttachmentCacheFile(
        namespaceKey: namespace.namespaceKey,
        attachmentID: publication.metadata.attachmentID,
        expectedPayloadIdentity: publication.metadata.payloadIdentity,
        stagedURL: staged,
        expectedByteCount: Int64(oldBytes.count),
        expectedSHA256: Data(SHA256.hash(data: oldBytes)),
        maximumBytes: 1_024,
        now: .distantPast
      )
      XCTFail("A replaced payload must not enter the cache.")
    } catch {
      XCTAssertEqual(error as? CloudAttachmentStorageError, .staleTransition)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
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
    let cached = try await library.installCloudAttachmentCacheFile(
      namespaceKey: namespace.namespaceKey,
      attachmentID: publication.metadata.attachmentID,
      expectedPayloadIdentity: publication.metadata.payloadIdentity,
      stagedURL: staged,
      expectedByteCount: Int64(bytes.count),
      expectedSHA256: Data(SHA256.hash(data: bytes)),
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

  private func snapshot(
    _ library: SwiftDataSnipLibrary,
    _ namespace: CloudSyncNamespace
  ) async throws -> CloudAttachmentStorageSnapshot {
    try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
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
    let cachedURL = try await library.installCloudAttachmentCacheFile(
      namespaceKey: namespace.namespaceKey,
      attachmentID: publication.metadata.attachmentID,
      expectedPayloadIdentity: publication.metadata.payloadIdentity,
      stagedURL: staged,
      expectedByteCount: Int64(bytes.count),
      expectedSHA256: Data(SHA256.hash(data: bytes)),
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
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sources = try names.map { name in
      let url = root.appendingPathComponent("\(name).txt")
      try Data("\(name) payload".utf8).write(to: url)
      return url
    }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    _ = try await library.perform(
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
    let namespace = namespaceValue()
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: CloudZoneID(name: "data", ownerName: "owner"),
      payloadZone: CloudZoneID(name: "payload", ownerName: "owner")
    )
    _ = try await store.pendingChanges()
    return PendingAttachmentFixture(
      root: root,
      library: library,
      namespace: namespace,
      store: store
    )
  }

  private func namespaceValue() -> CloudSyncNamespace {
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

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudAttachmentTransferTests-\(UUID().uuidString)", isDirectory: true)
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

private struct AvailableCacheFixture {
  let root: URL
  let bytes: Data
  let library: SwiftDataSnipLibrary
  let namespace: CloudSyncNamespace
  let attachmentID: UUID
  let cachedURL: URL
}

private struct PendingAttachmentFixture {
  let root: URL
  let library: SwiftDataSnipLibrary
  let namespace: CloudSyncNamespace
  let store: CloudFullSyncPersistence
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
