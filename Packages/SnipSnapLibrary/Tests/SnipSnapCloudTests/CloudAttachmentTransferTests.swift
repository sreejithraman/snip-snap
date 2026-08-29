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

  func testFailedUploadLeavesLocalSaveAndDurablePayloadWorkForLaterRun() async throws {
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
    try await resumed.sync()

    let settled = try await snapshot(reopened, namespace)
    XCTAssertTrue(try XCTUnwrap(settled.publications.first).metadataAccepted)
    XCTAssertFalse(FileManager.default.fileExists(atPath: durableUpload.path))
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
    XCTAssertTrue(metadataAccepted.cleanups.isEmpty)
    let oldAfterMetadata = await server.fullSnapshot(for: oldPayloadID)
    XCTAssertNotNil(oldAfterMetadata)

    try await sync.sync()

    let afterMetadataDeletion = try await snapshot(library, namespace)
    XCTAssertEqual(
      afterMetadataDeletion.cleanups.map(\.identity),
      [firstPublication.metadata.payloadIdentity]
    )
    let oldAfterMetadataDeletion = await server.fullSnapshot(for: oldPayloadID)
    XCTAssertNotNil(oldAfterMetadataDeletion)

    try await sync.sync()

    let oldAfterCleanup = await server.fullSnapshot(for: oldPayloadID)
    let newAfterCleanup = await server.fullSnapshot(for: newPayloadID)
    let finalStorage = try await snapshot(library, namespace)
    XCTAssertNil(oldAfterCleanup)
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
      operations: [.save(CloudAttachmentRecordCodec.metadataDraft(publication))]
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

  func testDirectVerifiedDownloadUsesBoundedCacheAndClearKeepsMetadata() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("payload.txt")
    let bytes = Data("download me".utf8)
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
      namespaceKey: namespace.canonicalKey,
      metadataZoneName: dataZone.name,
      metadataOwnerName: dataZone.ownerName,
      payloadZoneName: payloadZone.name,
      payloadOwnerName: payloadZone.ownerName
    )
    let initialSnapshot = try await snapshot(library, namespace)
    let initial = try XCTUnwrap(initialSnapshot.publications.first)
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
      namespaceKey: namespace.canonicalKey,
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
      operations: [.save(CloudAttachmentRecordCodec.metadataDraft(payloadAccepted))],
      zonesToSave: [dataZone]
    ))
    guard case .saved(let metadataSnapshot) = try XCTUnwrap(metadataResult.items.first) else {
      return XCTFail("Expected metadata save")
    }
    try await transport.confirmApplied(metadataResult.id)
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace.canonicalKey,
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
      maximumCacheBytes: 1024,
      now: { Date(timeIntervalSince1970: 10) }
    )
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
      maximumCacheBytes: 1024
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
      namespaceKey: namespace.canonicalKey
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
      maximumCacheBytes: 1024,
      now: { Date(timeIntervalSince1970: 11) }
    )
    _ = try await reopenedDownloads.downloadedURL(attachmentID: initial.metadata.attachmentID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
    for use in [
      CloudAttachmentUse.preview,
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
      operations: [.save(CloudAttachmentRecordCodec.metadataDraft(replacementPublication))]
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
      namespaceKey: namespace.canonicalKey,
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
      policy: CloudAttachmentCompatibilityPolicy(maximumFileBytes: 4)
    )
    XCTAssertEqual(unsupported.map(\.fileName), ["first.bin", "second.bin"])
  }

  private func snapshot(
    _ library: SwiftDataSnipLibrary,
    _ namespace: CloudSyncNamespace
  ) async throws -> CloudAttachmentStorageSnapshot {
    try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace.canonicalKey)
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
}
