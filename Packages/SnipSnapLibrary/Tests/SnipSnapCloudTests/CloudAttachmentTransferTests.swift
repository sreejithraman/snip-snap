import CloudKit
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
    let oldPayloadID = CloudAttachmentRecordCodec.recordID(target.metadata.payloadIdentity)
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
    let replacementID = replacement.metadata.attachmentID
    let newMetadataID = CloudAttachmentRecordCodec.recordID(replacement.metadataIdentity)
    let freshPayloadID = CloudAttachmentRecordCodec.recordID(replacement.metadata.payloadIdentity)
    XCTAssertNotEqual(replacementID, oldAttachmentID)
    XCTAssertNotEqual(replacement.metadataIdentity, target.metadataIdentity)
    XCTAssertNotEqual(freshPayloadID, oldPayloadID)
    XCTAssertFalse(replacement.payloadAccepted)
    XCTAssertFalse(replacement.metadataAccepted)
    let domain = try await library.checkedSnapshot(sortedBy: .manual)
    let domainSnip = try XCTUnwrap(domain.snips.first(where: { $0.id == snipID }))
    XCTAssertFalse(domainSnip.attachments.contains(where: { $0.id == oldAttachmentID }))
    XCTAssertTrue(domainSnip.attachments.contains(where: { $0.id == replacementID }))

    try await sync.sendPending()

    let afterUpload = try await snapshot(library, namespace)
    let uploaded = try publication(of: replacementID, in: afterUpload)
    XCTAssertTrue(uploaded.payloadAccepted)
    XCTAssertFalse(uploaded.metadataAccepted)
    let freshPayload = await server.fullSnapshot(for: freshPayloadID)
    let metadataBeforePublish = await server.fullSnapshot(for: newMetadataID)
    let oldPayloadBeforePublish = await server.fullSnapshot(for: oldPayloadID)
    XCTAssertNotNil(freshPayload)
    XCTAssertNil(metadataBeforePublish)
    XCTAssertNotNil(oldPayloadBeforePublish)

    try await sync.sendPending()

    let afterPublish = try await snapshot(library, namespace)
    XCTAssertTrue(try publication(of: replacementID, in: afterPublish).metadataAccepted)
    let newMetadata = try await serverAttachmentMetadata(newMetadataID, on: server)
    XCTAssertEqual(CloudAttachmentRecordCodec.recordID(newMetadata.payloadIdentity), freshPayloadID)
    let oldPayloadBeforeCleanup = await server.fullSnapshot(for: oldPayloadID)
    XCTAssertNotNil(oldPayloadBeforeCleanup)

    let cleanup = try await sync.sendPending()

    XCTAssertTrue(cleanup.settled)
    let oldMetadata = await server.fullSnapshot(for: oldMetadataID)
    let oldPayload = await server.fullSnapshot(for: oldPayloadID)
    let remainingPayload = await server.fullSnapshot(for: freshPayloadID)
    XCTAssertNil(oldMetadata)
    XCTAssertNil(oldPayload)
    XCTAssertNotNil(remainingPayload)
  }

  func testMetadataSaveAfterPeerDeletesPayloadRepublishesDownloadableAttachment() async throws {
    let owner = try await makeAttachmentClient(fileNames: ["original"])
    defer { try? FileManager.default.removeItem(at: owner.root) }
    try await owner.sync.sync()
    try await owner.sync.sync()
    let published = try await snapshot(owner.library, owner.namespace)
    let original = try XCTUnwrap(published.publications.first)
    let durableSource = try XCTUnwrap(original.localSourceURL)
    let bytes = Data("original payload".utf8)
    let oldMetadataID = CloudAttachmentRecordCodec.recordID(original.metadataIdentity)
    let oldPayloadID = CloudAttachmentRecordCodec.recordID(original.metadata.payloadIdentity)

    let peer = try attachmentClient(
      root: owner.root,
      storeURL: owner.root.appendingPathComponent("peer.store"),
      namespace: owner.namespace,
      server: owner.server,
      snipID: owner.snipID
    )
    try await peer.sync.fetchRemote()
    try await keepAttachments([], ofSnip: peer.snipID, in: peer.library)
    try await peer.sync.sendPending()
    let deletedMetadata = await owner.server.fullSnapshot(for: oldMetadataID)
    let payloadBeforeCleanup = await owner.server.fullSnapshot(for: oldPayloadID)
    XCTAssertNil(deletedMetadata)
    XCTAssertNotNil(payloadBeforeCleanup, "The metadata delete must precede payload cleanup.")

    // The peer can need two cleanup sends to learn the payload's accepted shadow and delete it.
    for _ in 0..<2 { try await peer.sync.sendPending() }
    let deletedPayload = await owner.server.fullSnapshot(for: oldPayloadID)
    let deleted = try await snapshot(peer.library, peer.namespace)
    XCTAssertNil(deletedPayload)
    XCTAssertTrue(deleted.publications.isEmpty)
    XCTAssertTrue(deleted.cleanups.isEmpty)

    let renamed = "renamed.txt"
    try await renameAttachment(ofSnip: owner.snipID, to: renamed, in: owner.library)
    try await owner.sync.sendPending(beforeSend: { batch in
      XCTAssertTrue(batch.operations.contains { operation in
        guard case .save(let draft) = operation else { return false }
        return draft.id == oldMetadataID && draft.base != nil
      }, "The owner's stale metadata save must reach the server.")
    })
    let recovered = try await snapshot(owner.library, owner.namespace)
    let replacement = try XCTUnwrap(recovered.publications.first)
    let attachmentID = replacement.metadata.attachmentID
    let metadataID = CloudAttachmentRecordCodec.recordID(replacement.metadataIdentity)
    XCTAssertNotEqual(attachmentID, original.metadata.attachmentID)
    XCTAssertNotEqual(metadataID, oldMetadataID)

    try await owner.sync.sendPending()
    let afterFirstFollowUp = try await snapshot(owner.library, owner.namespace)
    let firstFollowUp = try publication(of: attachmentID, in: afterFirstFollowUp)
    if firstFollowUp.payloadAccepted,
       firstFollowUp.metadata.payloadIdentity != original.metadata.payloadIdentity {
      let metadataBeforePublish = await owner.server.fullSnapshot(for: metadataID)
      XCTAssertNil(metadataBeforePublish, "The fresh payload must be accepted before metadata is published.")
    }
    let settled = try await owner.sync.sendPendingUntilSettled()
    XCTAssertTrue(settled.settled)
    let finished = try await snapshot(owner.library, owner.namespace)
    let republished = try publication(of: attachmentID, in: finished)
    XCTAssertEqual(republished.localSourceURL, durableSource)
    XCTAssertEqual(try Data(contentsOf: durableSource), bytes)
    let ownerSnapshot = try await owner.library.checkedSnapshot(sortedBy: .manual)
    let ownerSnip = try XCTUnwrap(ownerSnapshot.snips.first { $0.id == owner.snipID })
    XCTAssertEqual(ownerSnip.attachments.map(\.id), [attachmentID])
    XCTAssertEqual(ownerSnip.attachments.map(\.fileName), [renamed])

    let wireMetadata = try await serverAttachmentMetadata(metadataID, on: owner.server)
    let payloadID = CloudAttachmentRecordCodec.recordID(wireMetadata.payloadIdentity)
    XCTAssertEqual(wireMetadata.fileName, renamed)
    XCTAssertNotEqual(payloadID, oldPayloadID, "Replacement metadata must name a fresh payload.")
    let serverAsset = await owner.server.asset(for: payloadID, field: CloudAttachmentRecordCodec.assetField)
    let serverBytes = serverAsset.flatMap { try? Data(contentsOf: $0) }
    XCTAssertEqual(serverBytes, bytes, "The server must have the replacement bytes.")
    let finalOldMetadata = await owner.server.fullSnapshot(for: oldMetadataID)
    let finalOldPayload = await owner.server.fullSnapshot(for: oldPayloadID)
    XCTAssertNil(finalOldMetadata)
    XCTAssertNil(finalOldPayload)

    try await peer.sync.fetchRemote()
    let received = try await snapshot(peer.library, peer.namespace)
    let remote = try publication(of: attachmentID, in: received)
    XCTAssertTrue(remote.metadataAccepted)
    XCTAssertNil(remote.localSourceURL)
    XCTAssertNil(remote.sourceURL)
    XCTAssertTrue(received.cacheEntries.isEmpty)
    let transfers = CloudAttachmentTransferCoordinator(
      library: peer.library,
      namespace: peer.namespace,
      payloadZone: oldPayloadID.zone,
      transport: peer.transport,
      maximumCacheBytes: 1_024
    )
    do {
      let opened = try await transfers.prepare(attachmentID: attachmentID, for: .open)
      XCTAssertEqual(try Data(contentsOf: opened), bytes)
    } catch CloudAttachmentStorageError.missingPayload {
      XCTFail("Opening the replacement on the peer failed with missingPayload.")
    }
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
      previousPayload: remaining.metadata.payloadIdentity,
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
      previousPayload: remaining.metadata.payloadIdentity,
      replacedAttachmentID: remaining.metadata.attachmentID,
      remappedAttachmentID: remappedAttachmentID,
      remappedMetadataIdentity: remappedMetadataIdentity
    )
  }

  func testUnknownMetadataSavePreservesAnAlreadyQueuedPayload() async throws {
    let owner = try await makeAttachmentClient(fileNames: ["original"])
    defer { try? FileManager.default.removeItem(at: owner.root) }
    try await owner.sync.sync()
    try await owner.sync.sync()
    let published = try await snapshot(owner.library, owner.namespace)
    let original = try XCTUnwrap(published.publications.first)
    let durableSource = try XCTUnwrap(original.localSourceURL)
    let oldMetadataID = CloudAttachmentRecordCodec.recordID(original.metadataIdentity)
    let oldPayload = original.metadata.payloadIdentity

    let peer = try attachmentClient(
      root: owner.root,
      storeURL: owner.root.appendingPathComponent("peer.store"),
      namespace: owner.namespace,
      server: owner.server,
      snipID: owner.snipID
    )
    try await peer.sync.fetchRemote()
    try await keepAttachments([], ofSnip: peer.snipID, in: peer.library)
    try await peer.sync.sendPending()
    let peerStorage = try await snapshot(peer.library, peer.namespace)
    XCTAssertEqual(peerStorage.cleanups.map(\.identity), [oldPayload])

    try await renameAttachment(ofSnip: owner.snipID, to: "renamed.txt", in: owner.library)
    let frozen = try await owner.store.pendingChanges()
    XCTAssertTrue(frozen.operations.contains { operation in
      guard case .save(let draft) = operation else { return false }
      return draft.id == oldMetadataID && draft.base != nil
    })
    let sent = try await owner.transport.send(frozen)
    XCTAssertTrue(sent.items.contains(.unknownItem(oldMetadataID)))

    let bytes = Data("new bytes while the rename is in flight".utf8)
    try bytes.write(to: durableSource)
    _ = try await owner.store.pendingChanges()
    let beforeRemap = try await snapshot(owner.library, owner.namespace)
    let queued = try publication(of: original.metadata.attachmentID, in: beforeRemap)
    let queuedPayload = queued.metadata.payloadIdentity
    let queuedSource = try XCTUnwrap(queued.sourceURL)
    XCTAssertNotEqual(queuedPayload, oldPayload)
    XCTAssertFalse(queued.payloadAccepted)
    XCTAssertEqual(try Data(contentsOf: queuedSource), bytes)

    try await owner.store.stage(.sent(sent), outbound: frozen)
    try await owner.store.applyStaged(sent.id)
    try await owner.transport.confirmApplied(sent.id)

    let remapped = try await snapshot(owner.library, owner.namespace)
    let replacement = try XCTUnwrap(remapped.publications.first)
    XCTAssertNotEqual(replacement.metadata.attachmentID, original.metadata.attachmentID)
    XCTAssertEqual(replacement.metadata.payloadIdentity, queuedPayload)
    XCTAssertFalse(replacement.payloadAccepted)
    XCTAssertEqual(replacement.sourceURL, queuedSource)
    XCTAssertEqual(try Data(contentsOf: queuedSource), bytes)
    XCTAssertEqual(replacement.localSourceURL, durableSource)
    XCTAssertEqual(try Data(contentsOf: durableSource), bytes)
    let cleanup = try XCTUnwrap(remapped.cleanups.first(where: { $0.identity == oldPayload }))
    XCTAssertEqual(cleanup.blockedByAttachmentID, replacement.metadata.attachmentID)

    try await owner.sync.sendPending()

    let queuedID = CloudAttachmentRecordCodec.recordID(queuedPayload)
    let serverAsset = await owner.server.asset(for: queuedID, field: CloudAttachmentRecordCodec.assetField)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(serverAsset)), bytes)
    let oldPayloadRecord = await owner.server.fullSnapshot(for: CloudAttachmentRecordCodec.recordID(oldPayload))
    XCTAssertNotNil(oldPayloadRecord, "Old payload cleanup must wait for the replacement metadata.")
  }

  func testRemovingARemappedAttachmentStillCleansUpBothOldPayloads() async throws {
    let client = try await makeAttachmentClient(fileNames: ["original"])
    defer { try? FileManager.default.removeItem(at: client.root) }
    try await client.sync.sync()
    try await client.sync.sync()
    let published = try await snapshot(client.library, client.namespace)
    let original = try XCTUnwrap(published.publications.first)
    let durableFile = try XCTUnwrap(original.localSourceURL)
    try Data("changed bytes".utf8).write(to: durableFile)
    try await client.sync.sendPending()
    let afterUpload = try await snapshot(client.library, client.namespace)
    let uploaded = try publication(of: original.metadata.attachmentID, in: afterUpload)
    XCTAssertTrue(uploaded.payloadAccepted)
    XCTAssertFalse(uploaded.metadataAccepted)
    XCTAssertEqual(uploaded.priorPayloadIdentity, original.metadata.payloadIdentity)
    XCTAssertNotEqual(uploaded.metadata.payloadIdentity, original.metadata.payloadIdentity)
    let oldPayloads = [original.metadata.payloadIdentity, uploaded.metadata.payloadIdentity]

    let metadataID = CloudAttachmentRecordCodec.recordID(original.metadataIdentity)
    let serverRecord = await client.server.fullSnapshot(for: metadataID)
    let serverMetadata = try XCTUnwrap(serverRecord)
    let peerTransport = FakeCloudRecordTransport(server: client.server, namespace: client.namespace)
    let deleted = try await peerTransport.send(CloudOutboundBatch(operations: [
      .delete(metadataID, base: serverMetadata.shadow)
    ]))
    try await peerTransport.confirmApplied(deleted.id)
    try await client.sync.sendPending()

    let remapped = try await snapshot(client.library, client.namespace)
    let replacement = try XCTUnwrap(remapped.publications.first)
    XCTAssertNotEqual(replacement.metadata.attachmentID, original.metadata.attachmentID)
    XCTAssertFalse(replacement.payloadAccepted)
    XCTAssertNil(replacement.priorPayloadIdentity)
    XCTAssertEqual(Set(remapped.cleanups.map(\.identity)), Set(oldPayloads))
    for payload in oldPayloads {
      XCTAssertEqual(
        remapped.cleanups.first(where: { $0.identity == payload })?.blockedByAttachmentID,
        replacement.metadata.attachmentID
      )
      let record = await client.server.fullSnapshot(for: CloudAttachmentRecordCodec.recordID(payload))
      XCTAssertNotNil(record, "Both old payloads must still exist before the replacement is removed.")
    }

    try await keepAttachments([], ofSnip: client.snipID, in: client.library)
    let settled = try await client.sync.sendPendingUntilSettled()

    XCTAssertTrue(settled.settled)
    for payload in oldPayloads {
      let record = await client.server.fullSnapshot(for: CloudAttachmentRecordCodec.recordID(payload))
      XCTAssertNil(record, "Removing the replacement must release both old payload cleanups.")
    }
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
    let arrived = try await snapshot(pair.senderLibrary, pair.namespace)
    let arrivedSecond = try publication(of: second.id, in: arrived)
    let arrivedFirst = try publication(of: first.id, in: arrived)
    XCTAssertEqual(arrivedSecond.metadata.position, 0)
    XCTAssertEqual(arrivedFirst.metadata.position, 1)
    XCTAssertTrue(arrived.publications.allSatisfy { $0.metadataAccepted && $0.lastFailure == nil })
    let senderLocal = try await pair.senderLibrary.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(
      senderLocal.snips.first(where: { $0.id == pair.snipID })?.attachments.map(\.id),
      [second.id, first.id]
    )
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
    let freshPayload = firstSyncPublication.metadata.payloadIdentity
    XCTAssertNotEqual(freshPayload, restored.metadata.payloadIdentity)
    XCTAssertTrue(firstSyncPublication.payloadAccepted)
    XCTAssertFalse(firstSyncPublication.metadataAccepted)
    let freshPayloadRecord = await upgraded.server.fullSnapshot(
      for: CloudAttachmentRecordCodec.recordID(freshPayload)
    )
    XCTAssertNotNil(freshPayloadRecord, "The first sync must upload the restored attachment's fresh payload.")
    let metadataID = CloudAttachmentRecordCodec.recordID(firstSyncPublication.metadataIdentity)
    let firstSyncMetadata = await upgraded.server.fullSnapshot(for: metadataID)
    XCTAssertNil(firstSyncMetadata, "The first sync must leave the restored metadata pending.")

    let text = "edited after the upgrade"
    try await editText(ofSnip: client.snipID, to: text, in: upgraded.library)
    try await upgraded.sync.sync()
    let metadata = try await serverAttachmentMetadata(metadataID, on: upgraded.server)
    XCTAssertEqual(metadata.payloadIdentity, freshPayload)
    try await assertRestoreRepublished(held, in: upgraded, text: text)
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

  func testMissingZoneForAnObsoletePayloadSaveDoesNotBlockItsReplacement() async throws {
    let client = try await makeAttachmentClient(fileNames: [])
    defer { try? FileManager.default.removeItem(at: client.root) }
    let (original, outbound, sent) = try await sendFirstPayloadWithMissingZone(in: client)
    let oldPayloadID = CloudAttachmentRecordCodec.recordID(original.metadata.payloadIdentity)

    let durableFile = try XCTUnwrap(original.localSourceURL, "The attachment must keep its local file.")
    let replacementBytes = Data("replacement bytes after the first send".utf8)
    try replacementBytes.write(to: durableFile)
    let replacementPlan = try await client.store.pendingChanges()
    let reconciled = try await snapshot(client.library, client.namespace)
    let replacement = try publication(of: original.metadata.attachmentID, in: reconciled)
    let replacementPayloadID = CloudAttachmentRecordCodec.recordID(replacement.metadata.payloadIdentity)
    XCTAssertNotEqual(replacementPayloadID, oldPayloadID)
    XCTAssertFalse(replacement.payloadAccepted)
    XCTAssertTrue(replacementPlan.operations.contains { operation in
      guard case .save = operation else { return false }
      return operation.id == replacementPayloadID
    }, "The replacement payload must be pending upload.")
    XCTAssertFalse(
      replacementPlan.operations.contains { $0.id == oldPayloadID },
      "The submitted payload must be absent from the current plan."
    )

    try await client.store.stage(.sent(sent), outbound: outbound)
    try await client.store.applyStaged(sent.id)
    try await client.transport.confirmApplied(sent.id)

    let storage = try await snapshot(client.library, client.namespace)
    let pending = try publication(of: original.metadata.attachmentID, in: storage)
    XCTAssertEqual(pending.metadata.payloadIdentity, replacement.metadata.payloadIdentity)
    XCTAssertFalse(pending.payloadAccepted)
    XCTAssertNil(pending.lastFailure)
    let full = try await client.library.cloudFullStorageSnapshot(namespaceKey: client.namespace.namespaceKey)
    guard full.namespaceState.phase == .active else {
      return XCTFail("The obsolete payload failure must leave the namespace active, got \(full.namespaceState.phase).")
    }

    let settled = try await client.sync.sendPendingUntilSettled()
    XCTAssertTrue(settled.settled)
    let metadataID = CloudAttachmentRecordCodec.recordID(original.metadataIdentity)
    let metadata = try await serverAttachmentMetadata(metadataID, on: client.server)
    XCTAssertEqual(metadata.attachmentID, original.metadata.attachmentID)
    XCTAssertEqual(metadata.payloadIdentity, replacement.metadata.payloadIdentity)
    let asset = await client.server.asset(for: replacementPayloadID, field: CloudAttachmentRecordCodec.assetField)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(asset)), replacementBytes)
    let oldPayload = await client.server.fullSnapshot(for: oldPayloadID)
    XCTAssertNil(oldPayload)
  }

  func testLegacyStagedObsoletePayloadZoneFailureReplaysAfterReopen() async throws {
    let client = try await makeAttachmentClient(fileNames: [])
    defer { try? FileManager.default.removeItem(at: client.root) }
    let (original, outbound, sent) = try await sendFirstPayloadWithMissingZone(in: client)
    let oldID = CloudAttachmentRecordCodec.recordID(original.metadata.payloadIdentity)
    let durableFile = try XCTUnwrap(original.localSourceURL)
    let frozenSave = try XCTUnwrap(outbound.operations.first)
    guard case .save(let draft) = frozenSave else { return XCTFail("Expected a frozen payload save.") }
    let frozenAsset = try XCTUnwrap(draft.assetFields[CloudAttachmentRecordCodec.assetField])
    XCTAssertNotEqual(frozenAsset.fileURL, durableFile)
    let replacement = try await reconcileLegacyReplayReplacement(of: original, in: client)
    let replacementID = CloudAttachmentRecordCodec.recordID(replacement.metadata.payloadIdentity)
    let key = client.namespace.namespaceKey
    let before = try await client.library.cloudFullStorageSnapshot(namespaceKey: key)
    let beforeEngine = try await client.library.cloudTextSyncSnapshot(namespaceKey: key).engineState
    let beforeAttachments = try await snapshot(client.library, client.namespace)
    XCTAssertEqual(sent.databaseEvents, [.zoneSaved(oldID.zone)])
    XCTAssertNil(replacement.priorPayloadIdentity)
    XCTAssertFalse(replacement.payloadAccepted)
    XCTAssertFalse(replacement.metadataAccepted)
    XCTAssertNil(replacement.lastFailure)

    let legacy = try await persistLegacyPayloadZoneFailure(sent, outbound: outbound, in: client)
    XCTAssertTrue(legacy.items.isEmpty)
    XCTAssertTrue(legacy.attachmentTransitions.isEmpty)
    XCTAssertEqual(legacy.expectedEngineState, try XCTUnwrap(beforeEngine))
    let nextEngine = try JSONDecoder().decode(
      CloudEngineStateEnvelope.self, from: XCTUnwrap(legacy.nextEngineState)
    )
    XCTAssertEqual(nextEngine, sent.engineState)
    XCTAssertFalse(nextEngine.requiresInitialFetch)
    XCTAssertEqual(legacy.outboundBindings.map(\.identity), [original.metadata.payloadIdentity])
    let binding = try XCTUnwrap(legacy.outboundBindings.first)
    XCTAssertEqual(binding.action, .save)
    XCTAssertEqual(
      try JSONDecoder().decode(CloudOutboundOperation.self, from: binding.operationData), frozenSave
    )

    enum InterruptedReplay: Error { case beforeSave }
    let faultingLibrary = try SwiftDataSnipLibrary(
      storeURL: client.storeURL, afterMutationBeforeSave: { throw InterruptedReplay.beforeSave }
    )
    let faulting = attachmentClient(
      root: client.root, storeURL: client.storeURL, library: faultingLibrary,
      namespace: client.namespace, server: client.server, snipID: client.snipID
    )
    let beforeInterruption = try await faulting.store.stagedBatches()
    XCTAssertEqual(beforeInterruption, [legacy])
    do {
      try await faulting.sync.processAutomaticChanges()
      XCTFail("The injected error must interrupt replay before saving.")
    } catch InterruptedReplay.beforeSave {}
    let afterInterruption = try await faulting.store.stagedBatches()
    XCTAssertEqual(afterInterruption, [legacy])

    let upgraded = try await reopenLegacyPayloadReplay(legacy, in: client)
    let rolledBack = try await upgraded.library.cloudFullStorageSnapshot(namespaceKey: key)
    let rolledBackEngine = try await upgraded.library.cloudTextSyncSnapshot(namespaceKey: key).engineState
    let rolledBackAttachments = try await snapshot(upgraded.library, upgraded.namespace)
    XCTAssertEqual(rolledBack, before)
    XCTAssertEqual(rolledBackEngine, beforeEngine)
    XCTAssertEqual(rolledBackAttachments, beforeAttachments)
    try await upgraded.sync.processAutomaticChanges()

    let remaining = try await upgraded.store.stagedBatches()
    let applied = try await upgraded.library.cloudFullStorageSnapshot(namespaceKey: key)
    let appliedEngine = try await upgraded.library.cloudTextSyncSnapshot(namespaceKey: key).engineState
    let appliedAttachments = try await snapshot(upgraded.library, upgraded.namespace)
    XCTAssertTrue(remaining.isEmpty)
    XCTAssertEqual(appliedEngine, legacy.nextEngineState)
    XCTAssertEqual(appliedAttachments, beforeAttachments)
    guard applied.namespaceState.phase == .active else {
      return XCTFail("The obsolete staged save must leave the namespace active, got \(applied.namespaceState.phase).")
    }
    XCTAssertEqual(applied.namespaceState.revision, before.namespaceState.revision + 1)
    XCTAssertEqual(applied.enrolledEntities, before.enrolledEntities)

    // Redelivering the same receipt must leave no stage to apply on the next send.
    try await upgraded.library.stageCloudFullBatch(legacy)
    let duplicate = try await upgraded.store.stagedBatches()
    XCTAssertTrue(duplicate.isEmpty)
    try await upgraded.sync.processAutomaticChanges()
    let replayed = try await upgraded.library.cloudFullStorageSnapshot(namespaceKey: key)
    XCTAssertEqual(replayed, applied)

    let outcome = try await upgraded.sync.sendPendingUntilSettled()
    XCTAssertTrue(outcome.settled)
    let metadata = try await serverAttachmentMetadata(
      CloudAttachmentRecordCodec.recordID(original.metadataIdentity), on: upgraded.server
    )
    XCTAssertEqual(metadata, replacement.metadata)
    let asset = await upgraded.server.asset(for: replacementID, field: CloudAttachmentRecordCodec.assetField)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(asset)), Self.legacyReplayReplacementBytes)
    let acceptedReplacement = await upgraded.server.acceptedOperationCount(for: replacementID)
    let acceptedObsolete = await upgraded.server.acceptedOperationCount(for: oldID)
    XCTAssertEqual(acceptedReplacement, 1)
    XCTAssertEqual(acceptedObsolete, 0)
    let local = try await upgraded.library.checkedSnapshot(sortedBy: .manual)
    let attachmentID = original.metadata.attachmentID
    XCTAssertEqual(local.snips.first(where: { $0.id == client.snipID })?.attachments.map(\.id), [attachmentID])
    XCTAssertEqual(local.attachmentURLs[attachmentID], durableFile)
    XCTAssertEqual(try Data(contentsOf: durableFile), Self.legacyReplayReplacementBytes)

    let receiver = try attachmentClient(
      root: client.root, storeURL: client.root.appendingPathComponent("receiver.store"),
      namespace: client.namespace, server: client.server, snipID: client.snipID
    )
    try await receiver.sync.fetchRemote()
    let received = try await receiver.library.checkedSnapshot(sortedBy: .manual)
    let receivedSnip = try XCTUnwrap(received.snips.first { $0.id == receiver.snipID })
    XCTAssertEqual(receivedSnip.attachments.map(\.id), [attachmentID])
    XCTAssertNil(received.attachmentURLs[attachmentID])
    let receivedStorage = try await snapshot(receiver.library, receiver.namespace)
    let remote = try publication(of: attachmentID, in: receivedStorage)
    XCTAssertEqual(remote.metadataIdentity, original.metadataIdentity)
    XCTAssertEqual(remote.metadata.payloadIdentity, replacement.metadata.payloadIdentity)
    let downloads = CloudAttachmentTransferCoordinator(
      library: receiver.library, namespace: receiver.namespace, payloadZone: replacementID.zone,
      transport: receiver.transport, maximumCacheBytes: 1_024
    )
    let downloaded = try await downloads.download(attachmentID: attachmentID)
    XCTAssertEqual(try Data(contentsOf: downloaded), Self.legacyReplayReplacementBytes)
  }

  func testLegacyStagedPayloadFailureWithAnOwnedZoneEventStaysBlocked() async throws {
    enum Failure { case zone, database, reset(CloudZoneDeletionReason) }
    for failure in [Failure.zone, .database, .reset(.purged), .reset(.encryptedDataReset)] {
      let client = try await makeAttachmentClient(fileNames: [])
      defer { try? FileManager.default.removeItem(at: client.root) }
      let (original, outbound, sent) = try await sendFirstPayloadWithMissingZone(in: client)
      _ = try await reconcileLegacyReplayReplacement(of: original, in: client)
      let zone = CloudAttachmentRecordCodec.recordID(original.metadata.payloadIdentity).zone
      let (databaseEvents, zoneEvents): ([CloudDatabaseEvent], [CloudZoneEvent]) = switch failure {
      case .zone: (sent.databaseEvents, [.failed(zone, .zoneMissing)])
      case .database: ([.failed(zone, .zoneMissing)], [])
      case .reset(let reason): ([.zoneDeleted(zone, reason: reason)], [])
      }
      let reported = CloudSentBatch(
        id: sent.id, items: sent.items, databaseEvents: databaseEvents,
        zoneEvents: zoneEvents, engineState: sent.engineState
      )
      let staged = try await persistLegacyPayloadZoneFailure(
        reported, outbound: outbound, in: client, currentDecision: .blocked
      )
      let upgraded = try await reopenLegacyPayloadReplay(staged, in: client)
      let outcome = try await upgraded.sync.processAutomaticChanges()
      let key = client.namespace.namespaceKey
      let full = try await upgraded.library.cloudFullStorageSnapshot(namespaceKey: key)
      XCTAssertEqual(full.namespaceState.phase, .blocked, "Failure: \(failure)")
      if case .reset(let reason) = failure {
        XCTAssertEqual(outcome.result, .iCloudDataReset)
        XCTAssertTrue(outcome.blocksOutbound)
        XCTAssertFalse(outcome.settled)
        let restarted = try reopened(upgraded)
        let retained = try await restarted.library.cloudFullRecoveryEvents(namespaceKey: key)
        XCTAssertEqual(retained, staged.recoveryInputs)
        XCTAssertEqual(retained.map(\.kind), [.destructiveReset])
        XCTAssertEqual(try XCTUnwrap(retained.first).resultData, try XCTUnwrap(staged.rawBatchData))
        let persistedReason = try await restarted.store.destructiveResetSignal()
        XCTAssertEqual(persistedReason, reason)
      }
    }
  }

  func testLegacyStagedObsoletePayloadFailureStillChecksEngineAndNamespaceCAS() async throws {
    for mismatch in [CloudFullStorageError.engineStateMismatch, .namespaceStateMismatch] {
      let client = try await makeAttachmentClient(fileNames: [])
      defer { try? FileManager.default.removeItem(at: client.root) }
      let (original, outbound, sent) = try await sendFirstPayloadWithMissingZone(in: client)
      _ = try await reconcileLegacyReplayReplacement(of: original, in: client)
      let staged = try await persistLegacyPayloadZoneFailure(sent, outbound: outbound, in: client)
      let key = client.namespace.namespaceKey
      let before = try await client.library.cloudFullStorageSnapshot(namespaceKey: key)
      if mismatch == .engineStateMismatch {
        let dataZone = await client.store.dataZone
        try await client.store.saveEngineState(CloudEngineStateEnvelope(
          namespace: client.namespace, serialization: JSONEncoder().encode([dataZone: 999])
        ))
      } else {
        try await client.library.setCloudEnrollment(namespaceKey: key, references: before.enrolledEntities)
      }
      let changed = try await client.library.cloudFullStorageSnapshot(namespaceKey: key)
      let changedEngine = try await client.library.cloudTextSyncSnapshot(namespaceKey: key).engineState
      let upgraded = try await reopenLegacyPayloadReplay(staged, in: client)
      do {
        try await upgraded.sync.processAutomaticChanges()
        XCTFail("The legacy stage must reject \(mismatch).")
      } catch let error as CloudFullStorageError {
        XCTAssertEqual(error, mismatch)
      }
      let remaining = try await upgraded.store.stagedBatches()
      let after = try await upgraded.library.cloudFullStorageSnapshot(namespaceKey: key)
      let afterEngine = try await upgraded.library.cloudTextSyncSnapshot(namespaceKey: key).engineState
      XCTAssertEqual(remaining, [staged])
      XCTAssertEqual(after, changed)
      XCTAssertEqual(afterEngine, changedEngine)
    }
  }

  func testLegacyStagedPayloadFailureStaysBlockedWithoutAnUnambiguousObsoleteSave() async throws {
    enum FrozenSave: CaseIterable {
      case mismatchedBinding, missingAsset, emptyEngineState, currentPayload, priorPayload, queuedCleanup
    }
    for frozenSave in FrozenSave.allCases {
      let client = try await makeAttachmentClient(fileNames: [])
      defer { try? FileManager.default.removeItem(at: client.root) }
      let (original, outbound, sent) = try await sendFirstPayloadWithMissingZone(in: client)
      let key = client.namespace.namespaceKey
      let identity = original.metadata.payloadIdentity
      let attachmentID = original.metadata.attachmentID
      var submitted = outbound
      var reported = sent
      let bindings: [CloudFullOutboundBinding]?
      switch frozenSave {
      case .mismatchedBinding:
        _ = try await reconcileLegacyReplayReplacement(of: original, in: client)
        let delete = CloudOutboundOperation.delete(CloudAttachmentRecordCodec.recordID(identity), base: nil)
        bindings = [CloudFullOutboundBinding(
          identity: identity, action: .delete, operationData: try JSONEncoder().encode(delete)
        )]
      case .missingAsset:
        _ = try await reconcileLegacyReplayReplacement(of: original, in: client)
        guard case .save(let draft)? = outbound.operations.first else {
          return XCTFail("Expected a frozen payload save.")
        }
        submitted = CloudOutboundBatch(operations: [.save(CloudRecordDraft(
          id: draft.id, recordType: draft.recordType, schemaVersion: draft.schemaVersion,
          routingFields: draft.routingFields, encryptedFields: draft.encryptedFields
        ))], zonesToSave: outbound.zonesToSave)
        bindings = nil
      case .emptyEngineState:
        _ = try await reconcileLegacyReplayReplacement(of: original, in: client)
        reported = CloudSentBatch(
          id: sent.id, items: sent.items, databaseEvents: sent.databaseEvents,
          zoneEvents: sent.zoneEvents,
          engineState: CloudEngineStateEnvelope(namespace: client.namespace, serialization: Data())
        )
        bindings = nil
      case .currentPayload:
        let pending = try await snapshot(client.library, client.namespace)
        XCTAssertEqual(try publication(of: attachmentID, in: pending).metadata.payloadIdentity, identity)
        bindings = nil
      case .priorPayload:
        let payload = try payloadShadow(identity)
        let metadata = try metadataShadow(original.metadataIdentity)
        try await client.library.commitCloudAttachmentTransitions(namespaceKey: key, transitions: [
          .payloadAccepted(attachmentID: attachmentID, expectedRevision: original.revision,
            shadowData: payload.data, systemFields: payload.systemFields),
          .metadataAccepted(attachmentID: attachmentID, expectedRevision: original.revision + 1,
            shadowData: metadata.data, systemFields: metadata.systemFields),
        ])
        let replacement = try await reconcileLegacyReplayReplacement(of: original, in: client)
        XCTAssertEqual(replacement.priorPayloadIdentity, identity)
        bindings = nil
      case .queuedCleanup:
        try await keepAttachments([], ofSnip: client.snipID, in: client.library)
        let pending = try await client.store.pendingChanges()
        let removed = try await snapshot(client.library, client.namespace)
        XCTAssertTrue(removed.publications.isEmpty)
        XCTAssertEqual(removed.cleanups.map(\.identity), [identity])
        XCTAssertTrue(pending.operations.contains(.delete(CloudAttachmentRecordCodec.recordID(identity), base: nil)))
        bindings = nil
      }
      let staged = try await persistLegacyPayloadZoneFailure(
        reported, outbound: submitted, in: client, bindings: bindings
      )
      let upgraded = try await reopenLegacyPayloadReplay(staged, in: client)
      try await upgraded.sync.processAutomaticChanges()
      let full = try await upgraded.library.cloudFullStorageSnapshot(namespaceKey: key)
      XCTAssertEqual(full.namespaceState.phase, .blocked, "Frozen save: \(frozenSave)")
      if case .queuedCleanup = frozenSave {
        let remaining = try await snapshot(upgraded.library, upgraded.namespace)
        XCTAssertTrue(remaining.publications.isEmpty)
        XCTAssertEqual(remaining.cleanups.map(\.identity), [identity])
        XCTAssertNil(remaining.cleanups.first?.lastFailure)
      }
    }
  }

  func testLegacyStagedMixedSendKeepsItsBlockAndCommitsItsAcceptedWrite() async throws {
    let client = try await makeAttachmentClient(fileNames: [])
    defer { try? FileManager.default.removeItem(at: client.root) }
    let (original, outbound, firstSend) = try await sendFirstPayloadWithMissingZone(in: client)
    let oldID = CloudAttachmentRecordCodec.recordID(original.metadata.payloadIdentity)
    let dataZone = await client.store.dataZone
    let snipID = CloudRecordID.snip(client.snipID, in: dataZone)
    try await editText(ofSnip: client.snipID, to: "accepted beside a failed payload", in: client.library)
    let pending = try await client.store.pendingChanges()
    let snipSave = try XCTUnwrap(pending.operations.first { $0.id == snipID })
    let mixed = CloudOutboundBatch(operations: outbound.operations + [snipSave], zonesToSave: outbound.zonesToSave)
    let sending = FakeCloudRecordTransport(server: client.server, namespace: client.namespace)
    try await sending.start(state: firstSend.engineState)
    await sending.failNextSentItem(oldID, failure: .zoneMissing)
    let sent = try await sending.send(mixed)
    guard sent.items.contains(.failed(oldID, .zoneMissing)),
      case .saved(let acceptedSnip)? = sent.items.first(where: { $0.id == snipID })
    else { return XCTFail("The mixed receipt must contain the failed payload and the accepted snip.") }

    _ = try await reconcileLegacyReplayReplacement(of: original, in: client)
    let staged = try await persistLegacyPayloadZoneFailure(sent, outbound: mixed, in: client)
    let upgraded = try await reopenLegacyPayloadReplay(staged, in: client)
    try await upgraded.sync.processAutomaticChanges()
    let full = try await upgraded.library.cloudFullStorageSnapshot(namespaceKey: client.namespace.namespaceKey)
    XCTAssertEqual(full.namespaceState.phase, .blocked)
    let accepted = try XCTUnwrap(full.readyEntities.first { $0.reference.domainID == client.snipID })
    XCTAssertEqual(accepted.shadowData, acceptedSnip.shadow.data)
  }

  private static let legacyReplayReplacementBytes = Data("replacement bytes after the first send".utf8)

  private func reconcileLegacyReplayReplacement(
    of original: CloudAttachmentPublication, in client: AttachmentClient
  ) async throws -> CloudAttachmentPublication {
    let durableFile = try XCTUnwrap(original.localSourceURL)
    try Self.legacyReplayReplacementBytes.write(to: durableFile)
    let pending = try await client.store.pendingChanges()
    let storage = try await snapshot(client.library, client.namespace)
    let replacement = try publication(of: original.metadata.attachmentID, in: storage)
    let oldID = CloudAttachmentRecordCodec.recordID(original.metadata.payloadIdentity)
    let replacementID = CloudAttachmentRecordCodec.recordID(replacement.metadata.payloadIdentity)
    XCTAssertNotEqual(replacementID, oldID)
    XCTAssertFalse(pending.operations.contains { $0.id == oldID })
    guard case .save(let draft)? = pending.operations.first(where: { $0.id == replacementID }) else {
      throw CloudTransportError.invalidRecord
    }
    let asset = try XCTUnwrap(draft.assetFields[CloudAttachmentRecordCodec.assetField])
    XCTAssertEqual(try Data(contentsOf: asset.fileURL), Self.legacyReplayReplacementBytes)
    return replacement
  }

  private func persistLegacyPayloadZoneFailure(
    _ sent: CloudSentBatch, outbound: CloudOutboundBatch, in client: AttachmentClient,
    currentDecision: CloudNamespaceBootstrapPhase = .active,
    bindings: [CloudFullOutboundBinding]? = nil
  ) async throws -> CloudFullBatchCommit {
    let full = try await client.library.cloudFullStorageSnapshot(namespaceKey: client.namespace.namespaceKey)
    try await client.store.stage(.sent(sent), outbound: outbound)
    let staged = try await client.store.stagedBatches()
    let fresh = try XCTUnwrap(staged.first)
    XCTAssertEqual(staged.map(\.batchID), [sent.id])
    XCTAssertEqual(fresh.storageVersion, 1)
    XCTAssertTrue(fresh.hasPlannedDeferredReleases)
    XCTAssertEqual(fresh.expectedNamespaceRevision, full.namespaceState.revision)
    XCTAssertEqual(fresh.nextNamespaceState?.phase, currentDecision)
    let raw = try JSONDecoder().decode(
      CloudFullSyncPersistence.RawStagedBatch.self, from: XCTUnwrap(fresh.rawBatchData)
    )
    XCTAssertEqual(raw.storageVersion, 1)
    XCTAssertEqual(raw.batch, .sent(sent))
    XCTAssertEqual(raw.outbound, outbound)

    // The old planner treated this payload result as an owned-zone failure.
    let legacyDecision = full.namespaceState.committingSend(.ownedZoneMissing)
    XCTAssertEqual(legacyDecision.phase, .blocked)
    let legacy = CloudFullBatchCommit(
      namespaceKey: fresh.namespaceKey, batchID: fresh.batchID,
      expectedEngineState: fresh.expectedEngineState, nextEngineState: fresh.nextEngineState,
      nextEnrollment: fresh.nextEnrollment, expectedNamespaceRevision: fresh.expectedNamespaceRevision,
      nextNamespaceState: legacyDecision, rawBatchData: fresh.rawBatchData,
      outboundBindings: bindings ?? fresh.outboundBindings,
      recoveryInputs: fresh.recoveryInputs, recoveryChanges: fresh.recoveryChanges,
      recoveryReviews: fresh.recoveryReviews, graphRepairs: fresh.graphRepairs,
      settledDeleteIdentities: fresh.settledDeleteIdentities,
      attachmentTransitions: fresh.attachmentTransitions, items: fresh.items
    )
    try await client.library.replaceStagedCloudFullBatch(legacy)
    return legacy
  }

  private func reopenLegacyPayloadReplay(
    _ legacy: CloudFullBatchCommit, in client: AttachmentClient
  ) async throws -> AttachmentClient {
    let upgraded = try reopened(client)
    let persisted = try await upgraded.store.stagedBatches()
    XCTAssertEqual(persisted, [legacy], "Reopen must read the exact legacy v1 stage and raw bytes.")
    return upgraded
  }

  func testMissingZoneForTheCurrentPayloadSaveKeepsItRecoverable() async throws {
    let client = try await makeAttachmentClient(fileNames: [])
    defer { try? FileManager.default.removeItem(at: client.root) }
    let (original, outbound, sent) = try await sendFirstPayloadWithMissingZone(in: client)
    let payloadID = CloudAttachmentRecordCodec.recordID(original.metadata.payloadIdentity)

    try await client.store.stage(.sent(sent), outbound: outbound)
    try await client.store.applyStaged(sent.id)
    try await client.transport.confirmApplied(sent.id)

    let full = try await client.library.cloudFullStorageSnapshot(namespaceKey: client.namespace.namespaceKey)
    XCTAssertEqual(full.namespaceState.phase, .active)
    let storage = try await snapshot(client.library, client.namespace)
    let failed = try publication(of: original.metadata.attachmentID, in: storage)
    XCTAssertEqual(failed.metadata.payloadIdentity, original.metadata.payloadIdentity)
    XCTAssertEqual(failed.lastFailure, .zoneMissing)
    XCTAssertFalse(failed.payloadAccepted)
    XCTAssertFalse(failed.metadataAccepted)
    let accepted = await client.server.acceptedOperationCount(for: payloadID)
    XCTAssertEqual(accepted, 0)

    try await client.sync.prepareManualRetry()
    let retry = try await client.store.pendingChanges()
    XCTAssertTrue(retry.operations.contains { operation in
      guard case .save = operation else { return false }
      return operation.id == payloadID
    }, "Try Again must replan the same payload save.")
  }

  func testSentMissingZoneEventBlocksAttachmentNamespace() async throws {
    let client = try await makeAttachmentClient(fileNames: [])
    defer { try? FileManager.default.removeItem(at: client.root) }
    try await settleEmptySnip(in: client)
    let payloadZone = await client.store.payloadZone
    let zone = try XCTUnwrap(payloadZone)
    let sent = CloudSentBatch(
      id: UUID(),
      items: [],
      zoneEvents: [.failed(zone, .zoneMissing)],
      engineState: try await client.store.loadEngineState()
    )

    try await client.store.stage(.sent(sent), outbound: CloudOutboundBatch(operations: []))
    try await client.store.applyStaged(sent.id)

    let full = try await client.library.cloudFullStorageSnapshot(namespaceKey: client.namespace.namespaceKey)
    XCTAssertEqual(full.namespaceState.phase, .blocked)
  }

  func testMissingZoneForADataZoneSnipSaveBlocksAttachmentNamespace() async throws {
    let client = try await makeAttachmentClient(fileNames: [])
    defer { try? FileManager.default.removeItem(at: client.root) }
    try await settleEmptySnip(in: client)
    try await editText(ofSnip: client.snipID, to: "edit after enrollment", in: client.library)
    let dataZone = await client.store.dataZone
    let snipRecordID = CloudRecordID.snip(client.snipID, in: dataZone)
    let outbound = try await client.store.pendingChanges()
    XCTAssertEqual(outbound.operations.map(\.id), [snipRecordID])
    await client.transport.failNextSentItem(snipRecordID, failure: .zoneMissing)
    let sent = try await client.transport.send(outbound)
    XCTAssertEqual(sent.items, [.failed(snipRecordID, .zoneMissing)])

    try await client.store.stage(.sent(sent), outbound: outbound)
    try await client.store.applyStaged(sent.id)
    try await client.transport.confirmApplied(sent.id)

    let full = try await client.library.cloudFullStorageSnapshot(namespaceKey: client.namespace.namespaceKey)
    XCTAssertEqual(full.namespaceState.phase, .blocked)
  }

  private func sendFirstPayloadWithMissingZone(
    in client: AttachmentClient
  ) async throws -> (CloudAttachmentPublication, CloudOutboundBatch, CloudSentBatch) {
    try await settleEmptySnip(in: client)
    let source = client.root.appendingPathComponent("first-upload.txt")
    let bytes = Data("first upload bytes".utf8)
    try bytes.write(to: source)
    let local = try await client.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first { $0.id == client.snipID })
    _ = try await client.library.perform(.editAttachments(
      snipID: snip.id,
      content: snip.content,
      edits: [.added(sourceURL: source)],
      expectedUpdatedAt: snip.updatedAt,
      now: Date(timeIntervalSince1970: 1)
    ), sortedBy: .manual)
    let pending = try await client.store.pendingChanges()
    let storage = try await snapshot(client.library, client.namespace)
    let publication = try XCTUnwrap(storage.publications.first, "The fixture must queue its first upload.")
    let payloadID = CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity)
    let draft = try XCTUnwrap(pending.operations.compactMap { operation -> CloudRecordDraft? in
      guard case .save(let draft) = operation, draft.id == payloadID else { return nil }
      return draft
    }.first, "The first plan must save the payload.")
    XCTAssertEqual(draft.recordType, CloudAttachmentRecordCodec.payloadRecordType)
    let asset = try XCTUnwrap(draft.assetFields[CloudAttachmentRecordCodec.assetField])
    XCTAssertEqual(try Data(contentsOf: asset.fileURL), bytes)
    let outbound = CloudOutboundBatch(operations: [.save(draft)], zonesToSave: pending.zonesToSave)
    await client.transport.failNextSentItem(payloadID, failure: .zoneMissing)
    let sent = try await client.transport.send(outbound)
    XCTAssertEqual(sent.items, [.failed(payloadID, .zoneMissing)])
    XCTAssertTrue(sent.zoneEvents.isEmpty)
    return (publication, outbound, sent)
  }

  private func settleEmptySnip(in client: AttachmentClient) async throws {
    try await client.sync.sync()
    let settled = try await client.store.isSyncSettled()
    XCTAssertTrue(settled, "The empty snip must sync before the test sends a change.")
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

  /// One client with one snip whose attachments come from local files, enrolled but not synced.
  private func makeAttachmentClient(fileNames: [String]) async throws -> AttachmentClient {
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

  private func attachmentClient(
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

  private func attachmentClient(
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
  private func keepAttachments(
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

  /// Puts the snip back as it was before its attachments changed, as an undo does.
  private func restoreSnip(_ snip: Snip, in library: SwiftDataSnipLibrary) async throws {
    var snips = try await library.checkedSnapshot(sortedBy: .manual).snips
    let index = try XCTUnwrap(snips.firstIndex(where: { $0.id == snip.id }), "The snip must exist.")
    snips[index] = snip
    _ = try await library.perform(.replaceAll(snips), sortedBy: .manual)
  }

  /// Renames the snip's first attachment, as a whole-library replace does.
  private func renameAttachment(
    ofSnip snipID: UUID,
    to fileName: String,
    in library: SwiftDataSnipLibrary
  ) async throws {
    var snips = try await library.checkedSnapshot(sortedBy: .manual).snips
    let index = try XCTUnwrap(snips.firstIndex(where: { $0.id == snipID }), "The snip must exist.")
    snips[index].attachments[0].fileName = fileName
    _ = try await library.perform(.replaceAll(snips), sortedBy: .manual)
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

  private func snapshot(
    _ library: SwiftDataSnipLibrary,
    _ namespace: CloudSyncNamespace
  ) async throws -> CloudAttachmentStorageSnapshot {
    try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
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
    previousPayload: CloudTextStorageIdentity,
    replacedAttachmentID: UUID,
    remappedAttachmentID: UUID,
    remappedMetadataIdentity: CloudTextStorageIdentity,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let payloadsOwedCleanup = [removedPayload, previousPayload]
    let cleanupIDs = Set(payloadsOwedCleanup.map(CloudAttachmentRecordCodec.recordID))
    let remappedMetadataRecordID = CloudAttachmentRecordCodec.recordID(remappedMetadataIdentity)
    let remapped = try await snapshot(fixture.library, fixture.namespace)
    XCTAssertNil(remapped.publications.first(where: {
      $0.metadata.attachmentID == replacedAttachmentID
    }), "The remap must retire the replaced publication.", file: file, line: line)
    let replacement = try XCTUnwrap(remapped.publications.first(where: {
      $0.metadata.attachmentID == remappedAttachmentID
    }), "The remap must add the replacement publication.", file: file, line: line)
    let freshPayload = replacement.metadata.payloadIdentity
    XCTAssertNotEqual(freshPayload, previousPayload, file: file, line: line)
    XCTAssertFalse(replacement.payloadAccepted, file: file, line: line)
    XCTAssertFalse(
      replacement.metadataAccepted,
      "The replacement's metadata must start pending.",
      file: file,
      line: line
    )
    for payload in payloadsOwedCleanup {
      XCTAssertEqual(
        remapped.cleanups.first(where: { $0.identity == payload })?.blockedByAttachmentID,
        remappedAttachmentID,
        "Both cleanups must wait for the remapped replacement.",
        file: file,
        line: line
      )
    }

    let remappedBatch = try await fixture.store.pendingChanges()
    let beforePayload = remappedBatch.operations.map(\.id)
    let freshPayloadRecordID = CloudAttachmentRecordCodec.recordID(freshPayload)
    XCTAssertTrue(beforePayload.contains(freshPayloadRecordID), file: file, line: line)
    XCTAssertFalse(beforePayload.contains(remappedMetadataRecordID), file: file, line: line)
    XCTAssertTrue(
      cleanupIDs.isDisjoint(with: beforePayload),
      "The old payloads must stay while the fresh payload is pending.",
      file: file,
      line: line
    )
    let staged = try await snapshot(fixture.library, fixture.namespace)
    let stagedReplacement = try publication(of: remappedAttachmentID, in: staged)
    let acceptedPayload = try payloadShadow(freshPayload)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.payloadAccepted(
        attachmentID: remappedAttachmentID,
        expectedRevision: stagedReplacement.revision,
        shadowData: acceptedPayload.data,
        systemFields: acceptedPayload.systemFields
      )]
    )

    let afterPayload = try await fixture.store.pendingChanges()
    XCTAssertTrue(
      afterPayload.operations.contains(where: { $0.id == remappedMetadataRecordID }),
      "The replacement's metadata save must be planned.",
      file: file,
      line: line
    )
    XCTAssertTrue(
      cleanupIDs.isDisjoint(with: afterPayload.operations.map(\.id)),
      "The old payloads must stay until the replacement's metadata is accepted.",
      file: file,
      line: line
    )
    let ready = try await snapshot(fixture.library, fixture.namespace)
    let readyReplacement = try XCTUnwrap(ready.publications.first(where: {
      $0.metadata.attachmentID == remappedAttachmentID
    }), "The replacement must still be pending after planning.", file: file, line: line)
    let shadow = try metadataShadow(remappedMetadataIdentity)
    try await fixture.library.commitCloudAttachmentTransitions(
      namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.metadataAccepted(
        attachmentID: remappedAttachmentID,
        expectedRevision: readyReplacement.revision,
        shadowData: shadow.data,
        systemFields: shadow.systemFields
      )]
    )

    let releasedBatch = try await fixture.store.pendingChanges()

    XCTAssertTrue(
      cleanupIDs.isSubset(of: releasedBatch.operations.map(\.id)),
      "Accepting the replacement's metadata must release both old payload cleanups.",
      file: file,
      line: line
    )
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

  private func makeLocalAttachmentSeed(names: [String]) async throws -> LocalAttachmentSeed {
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
    let savedSnip = try XCTUnwrap(added.snips.first(where: { $0.content == "two attachments" }))
    let snipID = savedSnip.id
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
    XCTAssertEqual(receivedSnip.attachments.map(\.id), savedSnip.attachments.map(\.id))
    XCTAssertEqual(receivedSnip.attachments.map(\.fileName), contents.map { $0.fileName })
    let receivedStorage = try await snapshot(receiverLibrary, namespace)
    var attachments: [DownloadedPairAttachment] = []
    for (attachment, content) in zip(receivedSnip.attachments, contents) {
      let remote = try publication(of: attachment.id, in: receivedStorage)
      let original = try publication(of: attachment.id, in: published)
      XCTAssertTrue(remote.metadataAccepted)
      XCTAssertNil(remote.localSourceURL)
      XCTAssertEqual(remote.metadataIdentity, original.metadataIdentity)
      XCTAssertEqual(remote.metadata.payloadIdentity, original.metadata.payloadIdentity)
      let cachedURL = try await downloads.download(attachmentID: attachment.id)
      XCTAssertEqual(try Data(contentsOf: cachedURL), content.bytes)
      attachments.append(DownloadedPairAttachment(
        id: attachment.id,
        fileName: content.fileName,
        bytes: content.bytes,
        metadataIdentity: original.metadataIdentity,
        payloadIdentity: original.metadata.payloadIdentity,
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
      sender: sender,
      receiverLibrary: receiverLibrary,
      receiverStore: receiverStore,
      receiver: receiver,
      receiverTransport: receiverTransport,
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

// MARK: Concurrent attachment edits

extension CloudAttachmentTransferTests {
  func testCompletedPeerReorderReplacesTheCachedOrderAndKeepsAnIndependentRename() async throws {
    let owner = try await makeAttachmentClient(fileNames: ["a", "b", "c"])
    defer { try? FileManager.default.removeItem(at: owner.root) }
    try await owner.sync.sync()
    try await owner.sync.sync()
    let original = try await owner.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(original.snips.first(where: { $0.id == owner.snipID }))
    let idsByName = Dictionary(uniqueKeysWithValues: snip.attachments.map { ($0.fileName, $0.id) })
    let first = try XCTUnwrap(idsByName["a.txt"])
    let second = try XCTUnwrap(idsByName["b.txt"])
    let third = try XCTUnwrap(idsByName["c.txt"])
    XCTAssertEqual(snip.attachments.map(\.id), [first, second, third])
    let peer = try attachmentClient(
      root: owner.root,
      storeURL: owner.root.appendingPathComponent("peer.store"),
      namespace: owner.namespace,
      server: owner.server,
      snipID: owner.snipID
    )
    try await peer.sync.fetchRemote()
    try await keepAttachments([second, first, third], ofSnip: owner.snipID, in: peer.library)
    try await renameAttachment(ofSnip: owner.snipID, to: "local-b.txt", in: peer.library)
    try await keepAttachments([first, third, second], ofSnip: owner.snipID, in: owner.library)
    try await renameAttachment(ofSnip: owner.snipID, to: "remote-a.txt", in: owner.library)
    try await owner.sync.sendPendingUntilSettled()

    let expectedOrder = [first, third, second]
    let published = try await snapshot(owner.library, owner.namespace)
    for (position, id) in expectedOrder.enumerated() {
      let attachment = try publication(of: id, in: published)
      let recordID = CloudAttachmentRecordCodec.recordID(attachment.metadataIdentity)
      let server = try await serverAttachmentMetadata(recordID, on: owner.server)
      XCTAssertEqual(server.position, position, "The peer must fetch a complete remote order.")
    }
    try await peer.sync.fetchRemote()

    let fetched = try await peer.library.checkedSnapshot(sortedBy: .manual)
    let fetchedSnip = try XCTUnwrap(fetched.snips.first(where: { $0.id == owner.snipID }))
    XCTAssertEqual(fetchedSnip.attachments.map(\.id), expectedOrder)
    XCTAssertEqual(fetchedSnip.attachments.map(\.fileName), ["remote-a.txt", "c.txt", "local-b.txt"])
    let fetchedStorage = try await snapshot(peer.library, owner.namespace)
    for (position, id) in expectedOrder.enumerated() {
      XCTAssertEqual(try publication(of: id, in: fetchedStorage).metadata.position, position)
    }
    try await peer.sync.sendPendingUntilSettled()
    for (position, id) in expectedOrder.enumerated() {
      let attachment = try publication(of: id, in: published)
      let recordID = CloudAttachmentRecordCodec.recordID(attachment.metadataIdentity)
      let server = try await serverAttachmentMetadata(recordID, on: owner.server)
      XCTAssertEqual(server.position, position)
      if id == second { XCTAssertEqual(server.fileName, "local-b.txt") }
    }
  }

  func testLocalSourceRenameUndoSurvivesLosingTheSaveResultBeforeStaging() async throws {
    enum Interruption: Error { case beforeStaging }

    let owner = try await makeAttachmentClient(fileNames: ["a"])
    defer { try? FileManager.default.removeItem(at: owner.root) }
    try await owner.sync.sync()
    try await owner.sync.sync()
    let original = try await owner.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(original.snips.first(where: { $0.id == owner.snipID }))
    let attachment = try XCTUnwrap(snip.attachments.first)
    let published = try await snapshot(owner.library, owner.namespace)
    let row = try publication(of: attachment.id, in: published)
    let recordID = CloudAttachmentRecordCodec.recordID(row.metadataIdentity)
    XCTAssertTrue(row.metadataAccepted)
    XCTAssertNotNil(row.localSourceURL)
    try await renameAttachment(ofSnip: owner.snipID, to: "b.txt", in: owner.library)
    do {
      try await owner.sync.sendPending(beforeApply: { throw Interruption.beforeStaging })
      XCTFail("Expected the save result to be lost before staging.")
    } catch Interruption.beforeStaging {}
    let staged = try await owner.store.stagedBatches()
    XCTAssertTrue(staged.isEmpty)
    let saved = try await serverAttachmentMetadata(recordID, on: owner.server)
    XCTAssertEqual(saved.fileName, "b.txt")

    try await restoreSnip(snip, in: owner.library)
    let relaunched = try reopened(owner)
    try await relaunched.sync.fetchRemote()

    let fetched = try await relaunched.library.checkedSnapshot(sortedBy: .manual)
    let restored = try XCTUnwrap(fetched.snips.first(where: { $0.id == owner.snipID }))
    XCTAssertEqual(restored.attachments.map(\.fileName), ["a.txt"])
    try await relaunched.sync.sendPendingUntilSettled()
    let server = try await serverAttachmentMetadata(recordID, on: owner.server)
    XCTAssertEqual(server.fileName, "a.txt")
    XCTAssertEqual(server.payloadIdentity, row.metadata.payloadIdentity)
  }

  func testFrozenAttachmentReorderDoesNotResendAnEarlierPeerRename() async throws {
    try await assertFrozenAttachmentConflict(laterName: nil)
  }

  func testStaleAttachmentConflictReplanKeepsALaterLocalRename() async throws {
    try await assertFrozenAttachmentConflict(laterName: "later-local-name.txt")
  }

  private func assertFrozenAttachmentConflict(laterName: String?) async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await pair.sender.fetchRemote()
    try await editDownloadedAttachments(pair, keeping: [pair.second.id, pair.first.id])
    let frozen = try await pair.receiverStore.pendingChanges()
    XCTAssertTrue(plansMetadataSave(for: pair.first, in: frozen))
    try await renameAttachment(ofSnip: pair.snipID, to: "earlier-peer-name.txt", in: pair.senderLibrary)
    try await pair.sender.sendPending()
    try await pair.receiver.fetchRemote()

    let received = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(received.snips.first(where: { $0.id == pair.snipID }))
    XCTAssertEqual(snip.attachments.map(\.id), [pair.second.id, pair.first.id])
    XCTAssertEqual(snip.attachments.map(\.fileName), [pair.second.fileName, "earlier-peer-name.txt"])
    let peerName = "latest-peer-name.txt"
    try await renameAttachment(ofSnip: pair.snipID, to: peerName, in: pair.senderLibrary)
    try await pair.sender.sendPending()
    let sent = try await pair.receiverTransport.send(frozen)
    let recordID = CloudAttachmentRecordCodec.recordID(pair.first.metadataIdentity)
    XCTAssertTrue(sent.items.contains { item in
      guard case .conflict(let id, _) = item else { return false }
      return id == recordID
    })
    try await pair.receiverStore.stage(.sent(sent), outbound: frozen)
    if let laterName {
      var renamed = snip
      renamed.attachments[1].fileName = laterName
      try await restoreSnip(renamed, in: pair.receiverLibrary)
      _ = try await pair.receiverStore.pendingChanges()
    }
    try await pair.receiverStore.applyStaged(sent.id)
    try await pair.receiverTransport.confirmApplied(sent.id)
    try await pair.receiver.sendPendingUntilSettled()
    let server = try await serverAttachmentMetadata(recordID, on: pair.server)
    XCTAssertEqual(server.fileName, laterName ?? peerName)
    XCTAssertEqual(server.position, 1)
    XCTAssertEqual(server.payloadIdentity, pair.first.payloadIdentity)
  }

  func testAttachmentReorderSurvivesConcurrentRenameAfterLostAcknowledgement() async throws {
    try await assertConcurrentAttachmentEditsAfterLostAcknowledgement(queueRename: false)
  }

  func testAttachmentReorderSurvivesQueuedRenameAfterLostAcknowledgement() async throws {
    try await assertConcurrentAttachmentEditsAfterLostAcknowledgement(queueRename: true)
  }

  func testAttachmentOrderUndoSurvivesTwoRenamesAfterLostAcknowledgement() async throws {
    enum Interruption: Error { case beforeCommit }

    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await pair.sender.fetchRemote()
    let initial = try await pair.senderLibrary.checkedSnapshot(sortedBy: .manual)
    var restored = try XCTUnwrap(initial.snips.first(where: { $0.id == pair.snipID }))
    let order = restored.attachments.map(\.id)
    try await keepAttachments(Array(order.reversed()), ofSnip: pair.snipID, in: pair.senderLibrary)
    do {
      try await pair.sender.sendPending(beforeApply: { throw Interruption.beforeCommit })
      XCTFail("Expected the reorder result to be lost before staging.")
    } catch Interruption.beforeCommit {}
    let firstID = CloudAttachmentRecordCodec.recordID(pair.first.metadataIdentity)
    let secondID = CloudAttachmentRecordCodec.recordID(pair.second.metadataIdentity)
    let reversedFirst = try await serverAttachmentMetadata(firstID, on: pair.server)
    let reversedSecond = try await serverAttachmentMetadata(secondID, on: pair.server)
    XCTAssertEqual([reversedFirst.position, reversedSecond.position], [1, 0])

    restored.attachments[0].fileName = "renamed-first.txt"
    restored.attachments[1].fileName = "renamed-second.txt"
    try await restoreSnip(restored, in: pair.senderLibrary)
    let reopened = try attachmentClient(
      root: pair.root,
      storeURL: pair.root.appendingPathComponent("sender.store"),
      namespace: pair.namespace,
      server: pair.server,
      snipID: pair.snipID
    )
    try await reopened.sync.sync()
    try await pair.receiver.fetchRemote()

    for library in [reopened.library, pair.receiverLibrary] {
      let local = try await library.checkedSnapshot(sortedBy: .manual)
      let snip = try XCTUnwrap(local.snips.first(where: { $0.id == pair.snipID }))
      XCTAssertEqual(snip.attachments.map(\.id), order)
      XCTAssertEqual(snip.attachments.map(\.fileName), restored.attachments.map(\.fileName))
    }
    let first = try await serverAttachmentMetadata(firstID, on: pair.server)
    let second = try await serverAttachmentMetadata(secondID, on: pair.server)
    XCTAssertEqual([first.position, second.position], [0, 1])
    XCTAssertEqual([first.fileName, second.fileName], restored.attachments.map(\.fileName))
  }

  private func assertConcurrentAttachmentEditsAfterLostAcknowledgement(queueRename: Bool) async throws {
    enum Interruption: Error { case beforeSend, beforeCommit }

    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await pair.sender.fetchRemote()
    let renamed = "renamed-first.txt"
    try await renameAttachment(ofSnip: pair.snipID, to: renamed, in: pair.senderLibrary)
    if queueRename {
      let metadataID = CloudAttachmentRecordCodec.recordID(pair.first.metadataIdentity)
      do {
        try await pair.sender.sendPending(beforeSend: { outbound in
          XCTAssertEqual(outbound.operations.map(\.id), [metadataID])
          throw Interruption.beforeSend
        })
        XCTFail("Expected the rename to stay queued.")
      } catch Interruption.beforeSend {}
    }
    try await editDownloadedAttachments(pair, keeping: [pair.second.id, pair.first.id])

    // Simulate the reordering client exiting after the server save and before staging the result.
    do {
      try await pair.receiver.sendPending(beforeApply: { throw Interruption.beforeCommit })
      XCTFail("Expected the result to be lost before commit.")
    } catch Interruption.beforeCommit {}
    let staged = try await pair.receiverStore.stagedBatches()
    XCTAssertTrue(staged.isEmpty)
    for (position, attachment) in [pair.second, pair.first].enumerated() {
      let id = CloudAttachmentRecordCodec.recordID(attachment.metadataIdentity)
      let saved = try await serverAttachmentMetadata(id, on: pair.server)
      XCTAssertEqual(saved.position, position, "The reorder reached the server before the interruption.")
      XCTAssertEqual(saved.fileName, attachment.fileName)
    }

    try await pair.sender.sync()
    let reopenedReceiver = try attachmentClient(
      root: pair.root,
      storeURL: pair.root.appendingPathComponent("receiver.store"),
      namespace: pair.namespace,
      server: pair.server,
      snipID: pair.snipID
    )
    try await reopenedReceiver.sync.fetchRemote()

    try await assertMergedAttachmentEdits(
      pair, renamedTo: renamed, receiver: reopenedReceiver.library
    )
  }

  func testAttachmentReorderRetryKeepsRenameThatLandedDuringSend() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    try await pair.sender.fetchRemote()
    let renamed = "renamed-first.txt"
    try await renameAttachment(ofSnip: pair.snipID, to: renamed, in: pair.senderLibrary)
    try await editDownloadedAttachments(pair, keeping: [pair.second.id, pair.first.id])

    // Let the rename reach the server after the reorder batch has taken its snapshot.
    let renamingClient = pair.sender
    try await pair.receiver.sendPending(beforeSend: { _ in
      try await renamingClient.sendPending()
    })
    let firstMetadataID = CloudAttachmentRecordCodec.recordID(pair.first.metadataIdentity)
    let beforeRetry = try await serverAttachmentMetadata(firstMetadataID, on: pair.server)
    XCTAssertEqual(beforeRetry.fileName, renamed)
    XCTAssertEqual(beforeRetry.position, 0, "The stale reorder must conflict on the renamed attachment.")

    try await pair.receiver.sendPendingUntilSettled()
    try await pair.sender.fetchRemote()
    try await pair.receiver.fetchRemote()

    try await assertMergedAttachmentEdits(pair, renamedTo: renamed, receiver: pair.receiverLibrary)
  }

  func testLateMetadataRejectionDoesNotBlockANewerRename() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let recordID = CloudAttachmentRecordCodec.recordID(pair.first.metadataIdentity)
    await pair.receiverTransport.failNextSentItem(recordID, failure: .rejected)
    try await renameAttachment(ofSnip: pair.snipID, to: "b.txt", in: pair.receiverLibrary)
    let frozen = try await pair.receiverStore.pendingChanges()
    let sent = try await pair.receiverTransport.send(frozen)
    XCTAssertEqual(sent.items, [.failed(recordID, .rejected)])
    try await renameAttachment(ofSnip: pair.snipID, to: "c.txt", in: pair.receiverLibrary)
    _ = try await pair.receiverStore.pendingChanges()
    try await pair.receiverStore.stage(.sent(sent), outbound: frozen)
    try await pair.receiverStore.applyStaged(sent.id)
    try await pair.receiverTransport.confirmApplied(sent.id)

    let storage = try await snapshot(pair.receiverLibrary, pair.namespace)
    let publication = try publication(of: pair.first.id, in: storage)
    XCTAssertEqual(publication.metadata.fileName, "c.txt")
    XCTAssertNil(publication.lastFailure)

    try await pair.receiver.sendPendingUntilSettled()
    let metadata = try await serverAttachmentMetadata(recordID, on: pair.server)
    XCTAssertEqual(metadata.fileName, "c.txt")
    XCTAssertEqual(metadata.payloadIdentity, pair.first.payloadIdentity)
  }

  func testUnplannedCachedAttachmentRenameSurvivesFetchingASnipTextEdit() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let renamed = "renamed-in-cache.txt"
    try await renameAttachment(ofSnip: pair.snipID, to: renamed, in: pair.receiverLibrary)
    let text = "updated on the other client"
    try await editText(ofSnip: pair.snipID, to: text, in: pair.senderLibrary)
    try await pair.sender.sendPending()
    try await pair.receiver.fetchRemote()

    let local = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == pair.snipID }))
    XCTAssertEqual(snip.content, text)
    XCTAssertEqual(snip.attachments.map(\.fileName), [renamed, pair.second.fileName])

    try FileManager.default.removeItem(at: pair.first.cachedURL)
    let previousFetches = await pair.assetFetches.count
    let opened = try await pair.downloads.prepare(attachmentID: pair.first.id, for: .open)
    XCTAssertEqual(try Data(contentsOf: opened), pair.first.bytes)
    let fetches = await pair.assetFetches.count
    XCTAssertEqual(fetches, previousFetches + 1)
    let afterOpen = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    let openedSnip = try XCTUnwrap(afterOpen.snips.first(where: { $0.id == pair.snipID }))
    XCTAssertEqual(openedSnip.attachments.map(\.fileName), [renamed, pair.second.fileName])

    try await pair.receiver.sendPendingUntilSettled()
    let metadataID = CloudAttachmentRecordCodec.recordID(pair.first.metadataIdentity)
    let server = try await serverAttachmentMetadata(metadataID, on: pair.server)
    XCTAssertEqual(server.fileName, renamed)
  }

  func testCachedAttachmentRenameUndoSurvivesAStagedSaveAcknowledgement() async throws {
    let pair = try await makeDownloadedAttachmentPair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let original = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(original.snips.first(where: { $0.id == pair.snipID }))
    let renamed = "renamed-before-undo.txt"
    try await renameAttachment(ofSnip: pair.snipID, to: renamed, in: pair.receiverLibrary)
    let outbound = try await pair.receiverStore.pendingChanges()
    let sent = try await pair.receiverTransport.send(outbound)
    try await pair.receiverStore.stage(.sent(sent), outbound: outbound)
    let metadataID = CloudAttachmentRecordCodec.recordID(pair.first.metadataIdentity)
    let saved = try await serverAttachmentMetadata(metadataID, on: pair.server)
    XCTAssertEqual(saved.fileName, renamed)

    try await restoreSnip(snip, in: pair.receiverLibrary)
    try await pair.receiverStore.applyStaged(sent.id)
    try await pair.receiverTransport.confirmApplied(sent.id)

    let local = try await pair.receiverLibrary.checkedSnapshot(sortedBy: .manual)
    let restored = try XCTUnwrap(local.snips.first(where: { $0.id == pair.snipID }))
    XCTAssertEqual(restored.attachments.map(\.fileName), snip.attachments.map(\.fileName))
    try await pair.receiver.sendPendingUntilSettled()
    let server = try await serverAttachmentMetadata(metadataID, on: pair.server)
    XCTAssertEqual(server.fileName, pair.first.fileName)
  }

  private func assertMergedAttachmentEdits(
    _ pair: DownloadedAttachmentPair,
    renamedTo fileName: String,
    receiver: SwiftDataSnipLibrary
  ) async throws {
    let order = [pair.second, pair.first]
    let fileNames = [pair.second.fileName, fileName]
    for (client, library) in [("original client", pair.senderLibrary), ("receiving client", receiver)] {
      let local = try await library.checkedSnapshot(sortedBy: .manual)
      let snip = try XCTUnwrap(local.snips.first(where: { $0.id == pair.snipID }), client)
      XCTAssertEqual(snip.attachments.map(\.id), order.map(\.id), client)
      XCTAssertEqual(snip.attachments.map(\.fileName), fileNames, client)
      let storage = try await snapshot(library, pair.namespace)
      for attachment in order {
        let published = try publication(of: attachment.id, in: storage)
        XCTAssertEqual(published.metadataIdentity, attachment.metadataIdentity, client)
        XCTAssertEqual(published.metadata.payloadIdentity, attachment.payloadIdentity, client)
        let url = try XCTUnwrap(local.attachmentURLs[attachment.id], "\(client): \(attachment.fileName)")
        XCTAssertEqual(try Data(contentsOf: url), attachment.bytes, client)
      }
    }

    for (position, attachment) in order.enumerated() {
      let id = CloudAttachmentRecordCodec.recordID(attachment.metadataIdentity)
      let metadata = try await serverAttachmentMetadata(id, on: pair.server)
      XCTAssertEqual(metadata.snipID, pair.snipID, "Server")
      XCTAssertEqual(metadata.attachmentID, attachment.id, "Server")
      XCTAssertEqual(metadata.position, position, "Server")
      XCTAssertEqual(metadata.fileName, fileNames[position], "Server")
      XCTAssertEqual(metadata.payloadIdentity, attachment.payloadIdentity, "Server")
      let payloadID = CloudAttachmentRecordCodec.recordID(metadata.payloadIdentity)
      let asset = await pair.server.asset(for: payloadID, field: CloudAttachmentRecordCodec.assetField)
      XCTAssertEqual(try Data(contentsOf: XCTUnwrap(asset)), attachment.bytes, "Server")
    }
    let metadataZone = CloudAttachmentRecordCodec.recordID(pair.first.metadataIdentity).zone
    let metadataTypes = await pair.server.storedRecordTypes(in: metadataZone)
    XCTAssertEqual(metadataTypes.filter { $0 == CloudAttachmentRecordCodec.metadataRecordType }.count, 2)
  }

  private func serverAttachmentMetadata(
    _ id: CloudRecordID,
    on server: FakeCloudServer
  ) async throws -> CloudAttachmentMetadataValue {
    let record = await server.fullSnapshot(for: id)
    return try CloudAttachmentRecordCodec.metadata(from: XCTUnwrap(record))
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
  let sender: CloudFullSyncCoordinator
  /// Client 2, which only fetched and downloaded.
  let receiverLibrary: SwiftDataSnipLibrary
  let receiverStore: CloudFullSyncPersistence
  let receiver: CloudFullSyncCoordinator
  let receiverTransport: FakeCloudRecordTransport
  let downloads: CloudAttachmentTransferCoordinator
  let assetFetches: AssetFetchCountingTransport
}

private struct DownloadedPairAttachment {
  let id: UUID
  let fileName: String
  let bytes: Data
  let metadataIdentity: CloudTextStorageIdentity
  let payloadIdentity: CloudTextStorageIdentity
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
