import CryptoKit
import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapPersistence

final class CloudAttachmentLifecycleTests: XCTestCase {
  // MARK: Publication lifecycle

  func testReplayedPayloadAndMetadataAcceptanceChangesNothing() async throws {
    let fixture = try await makeLocalAttachmentFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = fixture.publication
    let queuedUpload = try XCTUnwrap(pending.sourceURL)
    let acceptPayload = CloudAttachmentTransition.payloadAccepted(
      attachmentID: pending.metadata.attachmentID,
      expectedRevision: pending.revision,
      shadowData: Data("payload-shadow".utf8),
      systemFields: Data("payload-fields".utf8)
    )

    try await commit(fixture.library, [acceptPayload])
    let payloadStorage = try await attachmentStorage(fixture.library)
    let payloadPublication = try XCTUnwrap(payloadStorage.publications.first)
    XCTAssertTrue(payloadPublication.payloadAccepted)
    XCTAssertFalse(payloadPublication.metadataAccepted)
    XCTAssertEqual(payloadPublication.revision, pending.revision + 1)
    XCTAssertNil(payloadPublication.sourceURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: queuedUpload.path))

    try await commit(fixture.library, [acceptPayload])
    let payloadReplay = try await attachmentStorage(fixture.library)
    XCTAssertEqual(payloadReplay, payloadStorage)

    let acceptMetadata = CloudAttachmentTransition.metadataAccepted(
      attachmentID: pending.metadata.attachmentID,
      expectedRevision: payloadPublication.revision,
      shadowData: Data("metadata-shadow".utf8),
      systemFields: Data("metadata-fields".utf8)
    )
    try await commit(fixture.library, [acceptMetadata])
    let publishedStorage = try await attachmentStorage(fixture.library)
    let published = try XCTUnwrap(publishedStorage.publications.first)
    XCTAssertTrue(published.metadataAccepted)
    XCTAssertEqual(published.revision, payloadPublication.revision + 1)

    try await commit(fixture.library, [acceptMetadata, acceptPayload])
    let publishedReplay = try await attachmentStorage(fixture.library)
    XCTAssertEqual(publishedReplay, publishedStorage)
  }

  func testStaleAttachmentTransitionsThrowAndLeaveStorageUnchanged() async throws {
    let fixture = try await makeLocalAttachmentFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = fixture.publication
    let attachmentID = pending.metadata.attachmentID
    let queuedUpload = try XCTUnwrap(pending.sourceURL)

    try await assertStaleTransition(
      fixture.library,
      .payloadAccepted(
        attachmentID: attachmentID,
        expectedRevision: pending.revision + 1,
        shadowData: Data("payload-shadow".utf8),
        systemFields: Data()
      )
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: queuedUpload.path))
    try await assertStaleTransition(
      fixture.library,
      .metadataAccepted(
        attachmentID: attachmentID,
        expectedRevision: pending.revision,
        shadowData: Data("metadata-shadow".utf8),
        systemFields: Data()
      )
    )
    try await assertStaleTransition(
      fixture.library,
      .metadataDeleteAccepted(attachmentID: attachmentID, expectedRevision: pending.revision)
    )

    try await commit(fixture.library, [.payloadAccepted(
      attachmentID: attachmentID,
      expectedRevision: pending.revision,
      shadowData: Data("payload-shadow".utf8),
      systemFields: Data()
    )])
    try await assertStaleTransition(
      fixture.library,
      .payloadCollision(
        attachmentID: attachmentID,
        expectedRevision: pending.revision + 1,
        replacementIdentity: CloudTextStorageIdentity(
          zoneName: "payload",
          ownerName: "owner",
          recordName: UUID().uuidString.lowercased()
        )
      )
    )
  }

  func testRemovingAnAttachmentWithAPendingPayloadDropsItsPublicationAndOwesItsUploadACleanup() async throws {
    let fixture = try await makeLocalAttachmentFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let queuedUpload = try XCTUnwrap(fixture.publication.sourceURL, "The pending payload must have an upload copy.")
    _ = try await fixture.library.perform(.delete(ids: [fixture.snipID]), sortedBy: .manual)

    try await reconcile(fixture.library)

    let removed = try await attachmentStorage(fixture.library)
    XCTAssertTrue(removed.publications.isEmpty, "Never-published metadata needs no retained publication.")
    XCTAssertEqual(removed.cleanups.count, 1, "The upload may be in flight, so it must be owed a cleanup.")
    let cleanup = try XCTUnwrap(removed.cleanups.first, "The abandoned upload must have a cleanup.")
    XCTAssertEqual(cleanup.identity, fixture.publication.metadata.payloadIdentity, "The cleanup must name the abandoned payload.")
    XCTAssertNil(cleanup.shadowData, "CloudKit has not accepted a payload shadow yet.")
    XCTAssertNil(cleanup.blockedByAttachmentID, "No metadata ever named this payload.")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: queuedUpload.deletingLastPathComponent().path),
      "The abandoned upload copy must be removed after saving."
    )
    XCTAssertEqual(uploadDirectoryNames(root: fixture.root), [], "No upload directory may outlive the removal.")
  }

  func testRemovingAnAttachmentWithAnAcceptedPayloadCleansItUpAfterItsMetadataDelete() async throws {
    let fixture = try await makeLocalAttachmentFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = fixture.publication
    let queuedUpload = try XCTUnwrap(pending.sourceURL, "The pending payload must have an upload copy.")
    let payloadShadow = Data("payload-shadow".utf8)
    try await commit(fixture.library, [.payloadAccepted(
      attachmentID: pending.metadata.attachmentID,
      expectedRevision: pending.revision,
      shadowData: payloadShadow,
      systemFields: Data("payload-fields".utf8)
    )])
    _ = try await fixture.library.perform(.delete(ids: [fixture.snipID]), sortedBy: .manual)

    try await reconcile(fixture.library)

    let removed = try await attachmentStorage(fixture.library)
    let publication = try XCTUnwrap(removed.publications.first, "A metadata save may be in flight, so the publication must stay.")
    XCTAssertFalse(publication.isLocallyPresent, "The retained publication must record its removal.")
    XCTAssertTrue(removed.cleanups.isEmpty, "The payload must wait until its metadata is gone.")
    try await commit(fixture.library, [.metadataDeleteAccepted(
      attachmentID: publication.metadata.attachmentID,
      expectedRevision: publication.revision
    )])
    let deleted = try await attachmentStorage(fixture.library)
    XCTAssertTrue(deleted.publications.isEmpty, "An accepted metadata delete must retire the publication.")
    XCTAssertEqual(deleted.cleanups.count, 1, "An accepted metadata delete must owe one payload cleanup.")
    let cleanup = try XCTUnwrap(deleted.cleanups.first, "The accepted payload must have a cleanup.")
    XCTAssertEqual(cleanup.identity, pending.metadata.payloadIdentity, "The cleanup must name the accepted payload.")
    XCTAssertEqual(cleanup.shadowData, payloadShadow, "The cleanup must retain the accepted payload shadow.")
    XCTAssertNil(cleanup.blockedByAttachmentID, "There is no replacement at this location.")
    XCTAssertNil(cleanup.lastFailure, "The new cleanup must have no failure.")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: queuedUpload.deletingLastPathComponent().path),
      "Accepting the payload must release its upload copy."
    )
    XCTAssertEqual(uploadDirectoryNames(root: fixture.root), [], "No upload directory may remain.")
  }

  func testReplacingAFileWhileAPublishedAttachmentsEditIsPendingKeepsTheOldPayloadUntilTheNewMetadataPublishes() async throws {
    let fixture = try await makeLocalAttachmentFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let published = try await publishLocalAttachment(fixture)
    var snips = try await fixture.library.checkedSnapshot(sortedBy: .manual).snips
    let index = try XCTUnwrap(snips.firstIndex(where: { $0.id == fixture.snipID }), "The fixture must keep its snip.")
    snips[index].attachments[0].fileName = "renamed.txt"
    _ = try await fixture.library.perform(.replaceAll(snips), sortedBy: .manual)
    try await reconcile(fixture.library)
    let editedStorage = try await attachmentStorage(fixture.library)
    let edited = try XCTUnwrap(editedStorage.publications.first, "The metadata edit must keep the publication.")
    XCTAssertFalse(edited.metadataAccepted, "The rename must be pending before the file changes.")

    try await replaceFixtureFile(fixture)

    let replacedStorage = try await attachmentStorage(fixture.library)
    let replaced = try XCTUnwrap(replacedStorage.publications.first, "The replacement must keep the publication.")
    XCTAssertTrue(replacedStorage.cleanups.isEmpty, "Published metadata still names the old payload, so its cleanup must wait.")
    XCTAssertEqual(replaced.priorPayloadIdentity, published.metadata.payloadIdentity, "The old payload must wait as the replaced payload.")
    XCTAssertEqual(replaced.priorPayloadShadowData, published.payloadShadowData, "The replaced payload must retain its accepted shadow.")
    let reopened = try SwiftDataSnipLibrary(storeURL: fixture.storeURL)
    let reopenedStorage = try await attachmentStorage(reopened)
    XCTAssertEqual(reopenedStorage, replacedStorage, "The pending replacement must survive a reopen.")
    try await commit(reopened, [.payloadAccepted(
      attachmentID: replaced.metadata.attachmentID,
      expectedRevision: replaced.revision,
      shadowData: Data("replacement-payload-shadow".utf8),
      systemFields: Data()
    )])
    let payloadStorage = try await attachmentStorage(reopened)
    let payload = try XCTUnwrap(payloadStorage.publications.first, "Accepting the payload must keep the publication.")
    XCTAssertTrue(payloadStorage.cleanups.isEmpty, "The old payload must still wait for the new metadata.")
    try await commit(reopened, [.metadataAccepted(
      attachmentID: payload.metadata.attachmentID,
      expectedRevision: payload.revision,
      shadowData: Data("replacement-metadata-shadow".utf8),
      systemFields: Data()
    )])
    let accepted = try await attachmentStorage(reopened)
    XCTAssertEqual(accepted.cleanups.map(\.identity), [published.metadata.payloadIdentity], "Publishing the replacement must owe exactly the old payload a cleanup.")
    XCTAssertEqual(accepted.cleanups.first?.shadowData, published.payloadShadowData, "The cleanup must use the old payload shadow.")
  }

  func testRemovingAnAttachmentAfterItsFileWasReplacedKeepsItUntilItsMetadataDeleteIsAccepted() async throws {
    let fixture = try await makeLocalAttachmentFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let published = try await publishLocalAttachment(fixture)
    try await replaceFixtureFile(fixture)
    let replacedStorage = try await attachmentStorage(fixture.library)
    let replaced = try XCTUnwrap(replacedStorage.publications.first, "The replacement must keep the publication.")
    let upload = try XCTUnwrap(replaced.sourceURL, "The replacement payload must have an upload copy.")
    _ = try await fixture.library.perform(.delete(ids: [fixture.snipID]), sortedBy: .manual)

    try await reconcile(fixture.library)

    let removed = try await attachmentStorage(fixture.library)
    let publication = try XCTUnwrap(removed.publications.first, "Published metadata must be deleted before retiring the publication.")
    XCTAssertFalse(publication.isLocallyPresent, "The kept publication must record its removal.")
    XCTAssertEqual(publication.priorPayloadIdentity, published.metadata.payloadIdentity, "The published payload must remain owed after the replacement is removed.")
    XCTAssertEqual(removed.cleanups.count, 1, "Only the abandoned replacement upload may be owed now.")
    XCTAssertEqual(removed.cleanups.first?.identity, replaced.metadata.payloadIdentity, "The immediate cleanup must name the replacement upload.")
    XCTAssertNil(removed.cleanups.first?.shadowData, "The abandoned upload has no accepted shadow.")
    XCTAssertFalse(FileManager.default.fileExists(atPath: upload.deletingLastPathComponent().path), "The abandoned upload copy must be removed.")
    let reopened = try SwiftDataSnipLibrary(storeURL: fixture.storeURL)
    let reopenedStorage = try await attachmentStorage(reopened)
    XCTAssertEqual(reopenedStorage, removed, "Removal must preserve both payload obligations across a reopen.")
    try await commit(reopened, [.metadataDeleteAccepted(
      attachmentID: publication.metadata.attachmentID,
      expectedRevision: publication.revision
    )])
    let deleted = try await attachmentStorage(reopened)
    XCTAssertTrue(deleted.publications.isEmpty, "The accepted metadata delete must retire the publication.")
    XCTAssertEqual(Set(deleted.cleanups.map(\.identity)), Set([published.metadata.payloadIdentity, replaced.metadata.payloadIdentity]), "Both payloads must be owed cleanup after the metadata is gone.")
    XCTAssertEqual(deleted.cleanups.first(where: { $0.identity == published.metadata.payloadIdentity })?.shadowData, published.payloadShadowData, "The published payload's cleanup must keep its shadow.")
  }

  func testFetchingMetadataDeletionAfterAReplacementWasRemovedOwesBothPayloadsCleanup() async throws {
    let fixture = try await makeLocalAttachmentFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let published = try await publishLocalAttachment(fixture)
    try await replaceFixtureFile(fixture)
    let replacedStorage = try await attachmentStorage(fixture.library)
    let replaced = try XCTUnwrap(replacedStorage.publications.first, "The replacement must keep the publication.")
    XCTAssertFalse(replaced.payloadAccepted, "The replacement payload must still be pending.")
    XCTAssertEqual(replaced.priorPayloadIdentity, published.metadata.payloadIdentity, "The row must retain the published payload.")
    _ = try await fixture.library.perform(.delete(ids: [fixture.snipID]), sortedBy: .manual)
    try await reconcile(fixture.library)

    try await commit(fixture.library, [.remoteMetadataDeleted(
      metadataIdentity: published.metadataIdentity
    )])

    let deleted = try await attachmentStorage(fixture.library)
    XCTAssertTrue(deleted.publications.isEmpty, "The fetched metadata delete must retire the publication.")
    XCTAssertEqual(deleted.cleanups.count, 2, "Each payload must have exactly one cleanup.")
    XCTAssertEqual(Set(deleted.cleanups.map(\.identity)), Set([published.metadata.payloadIdentity, replaced.metadata.payloadIdentity]), "Both payloads must be owed cleanup after the fetched metadata delete.")
    XCTAssertEqual(deleted.cleanups.first(where: { $0.identity == published.metadata.payloadIdentity })?.shadowData, published.payloadShadowData, "The published payload's cleanup must keep its accepted shadow.")
  }

  func testRemovalSaveFailureKeepsThePublicationAndQueuedUploadAfterReopen() async throws {
    let fixture = try await makeLocalAttachmentFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let upload = try XCTUnwrap(fixture.publication.sourceURL, "The pending payload must have an upload copy.")
    _ = try await fixture.library.perform(.delete(ids: [fixture.snipID]), sortedBy: .manual)
    let before = try await attachmentStorage(fixture.library)
    let failing = try failingLibrary(storeURL: fixture.storeURL)

    do {
      try await reconcile(failing)
      XCTFail("The injected save failure must abort the removal.")
    } catch is InjectedSaveFailure {}

    let reopened = try SwiftDataSnipLibrary(storeURL: fixture.storeURL)
    let after = try await attachmentStorage(reopened)
    XCTAssertEqual(after, before, "A failed removal must persist neither lifecycle changes nor cleanups.")
    XCTAssertTrue(FileManager.default.fileExists(atPath: upload.path), "A failed removal must retain the queued upload copy.")
  }

  func testTransitionSaveFailureLeavesPublicationsCleanupsAndQueuedUploadUnchanged() async throws {
    let fixture = try await makeLocalAttachmentFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = fixture.publication
    let queuedUpload = try XCTUnwrap(pending.sourceURL)
    let removedRemotely = try await acceptRemoteAttachment(
      fixture.library,
      snipID: UUID(),
      position: 0,
      fileName: "removed.txt",
      bytes: Data("removed on another device".utf8)
    )
    try await commit(fixture.library, [.remoteMetadataDeleted(
      metadataIdentity: remoteMetadataIdentity(for: removedRemotely.attachmentID)
    )])
    let before = try await attachmentStorage(fixture.library)
    let cleanup = try XCTUnwrap(before.cleanups.first)
    XCTAssertEqual(cleanup.identity, removedRemotely.payloadIdentity)
    let transitions: [CloudAttachmentTransition] = [
      .payloadAccepted(
        attachmentID: pending.metadata.attachmentID,
        expectedRevision: pending.revision,
        shadowData: Data("payload-shadow".utf8),
        systemFields: Data()
      ),
      .cleanupAccepted(identity: cleanup.identity, expectedRevision: cleanup.revision),
    ]
    let failing = try failingLibrary(storeURL: fixture.storeURL)

    do {
      try await commit(failing, transitions)
      XCTFail("The injected save failure must abort the transition commit.")
    } catch is InjectedSaveFailure {}

    let afterFailure = try await attachmentStorage(fixture.library)
    XCTAssertEqual(afterFailure, before)
    XCTAssertTrue(FileManager.default.fileExists(atPath: queuedUpload.path))

    try await commit(fixture.library, transitions)

    let afterRetry = try await attachmentStorage(fixture.library)
    let accepted = try XCTUnwrap(afterRetry.publications.first)
    XCTAssertTrue(accepted.payloadAccepted)
    XCTAssertEqual(accepted.revision, pending.revision + 1)
    XCTAssertTrue(afterRetry.cleanups.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: queuedUpload.path))
  }

  func testReconcileSaveFailureCreatesNoPublicationOrQueuedUpload() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data("queued only after a saved reconcile".utf8)
    let source = root.appendingPathComponent("local.txt")
    try bytes.write(to: source)
    let storeURL = root.appendingPathComponent("store")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    try await addSnip(to: library, attaching: [source])
    let failing = try failingLibrary(storeURL: storeURL)

    do {
      try await reconcile(failing)
      XCTFail("The injected save failure must abort the reconcile.")
    } catch is InjectedSaveFailure {}

    let afterFailure = try await attachmentStorage(library)
    XCTAssertTrue(afterFailure.publications.isEmpty)
    XCTAssertTrue(afterFailure.cleanups.isEmpty)
    XCTAssertEqual(uploadDirectoryNames(root: root), [])

    try await reconcile(library)

    let afterRetry = try await attachmentStorage(library)
    XCTAssertEqual(afterRetry.publications.count, 1)
    let publication = try XCTUnwrap(afterRetry.publications.first)
    XCTAssertFalse(publication.payloadAccepted)
    let queuedUpload = try XCTUnwrap(publication.sourceURL)
    XCTAssertEqual(try Data(contentsOf: queuedUpload), bytes)
    XCTAssertEqual(
      uploadDirectoryNames(root: root),
      [queuedUpload.deletingLastPathComponent().lastPathComponent]
    )
  }

  func testClearingManuallyRetryableFailuresKeepsAutomaticAndBlockedFailures() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let failures: [CloudAttachmentFailure] = [
      .retryable, .quotaExceeded, .updateRequired, .accessDenied, .rejected,
      .attachmentMissing, .invalidRecord, .zoneMissing, .localStorage,
    ]
    let clearedFailures: Set<CloudAttachmentFailure> = [
      .quotaExceeded, .rejected, .attachmentMissing, .invalidRecord, .zoneMissing, .localStorage,
    ]
    var publicationFailures: [UUID: CloudAttachmentFailure] = [:]
    var cleanupFailures: [CloudTextStorageIdentity: CloudAttachmentFailure] = [:]
    var deletedRemotely: [CloudAttachmentTransition] = []
    for failure in failures {
      let published = try await acceptRemoteAttachment(
        library,
        snipID: UUID(),
        position: 0,
        fileName: "\(failure.rawValue).txt",
        bytes: Data(failure.rawValue.utf8)
      )
      publicationFailures[published.attachmentID] = failure
      let removed = try await acceptRemoteAttachment(
        library,
        snipID: UUID(),
        position: 0,
        fileName: "removed-\(failure.rawValue).txt",
        bytes: Data("removed \(failure.rawValue)".utf8)
      )
      cleanupFailures[removed.payloadIdentity] = failure
      deletedRemotely.append(.remoteMetadataDeleted(
        metadataIdentity: remoteMetadataIdentity(for: removed.attachmentID)
      ))
    }
    try await commit(library, deletedRemotely)
    let queued = try await attachmentStorage(library)
    XCTAssertEqual(queued.publications.count, failures.count)
    XCTAssertEqual(queued.cleanups.count, failures.count)
    var failedTransitions: [CloudAttachmentTransition] = []
    for publication in queued.publications {
      let failure = try XCTUnwrap(publicationFailures[publication.metadata.attachmentID])
      failedTransitions.append(.operationFailed(
        attachmentID: publication.metadata.attachmentID,
        expectedRevision: publication.revision,
        failure: failure
      ))
    }
    for cleanup in queued.cleanups {
      let failure = try XCTUnwrap(cleanupFailures[cleanup.identity])
      failedTransitions.append(.cleanupFailed(
        identity: cleanup.identity,
        expectedRevision: cleanup.revision,
        failure: failure
      ))
    }
    try await commit(library, failedTransitions)
    let failed = try await attachmentStorage(library)

    try await library.clearManuallyRetryableCloudAttachmentFailures(namespaceKey: namespace)

    let cleared = try await attachmentStorage(library)
    XCTAssertEqual(cleared.publications.count, failures.count)
    XCTAssertEqual(cleared.cleanups.count, failures.count)
    for publication in cleared.publications {
      let attachmentID = publication.metadata.attachmentID
      let failure = try XCTUnwrap(publicationFailures[attachmentID])
      let before = try XCTUnwrap(failed.publications.first(where: {
        $0.metadata.attachmentID == attachmentID
      }))
      XCTAssertEqual(before.lastFailure, failure)
      if clearedFailures.contains(failure) {
        XCTAssertNil(publication.lastFailure, "\(failure)")
        XCTAssertEqual(publication.revision, before.revision + 1, "\(failure)")
      } else {
        XCTAssertEqual(publication.lastFailure, failure)
        XCTAssertEqual(publication.revision, before.revision, "\(failure)")
      }
    }
    for cleanup in cleared.cleanups {
      let failure = try XCTUnwrap(cleanupFailures[cleanup.identity])
      let before = try XCTUnwrap(failed.cleanups.first(where: { $0.identity == cleanup.identity }))
      XCTAssertEqual(before.lastFailure, failure)
      if clearedFailures.contains(failure) {
        XCTAssertNil(cleanup.lastFailure, "\(failure)")
        XCTAssertEqual(cleanup.revision, before.revision + 1, "\(failure)")
      } else {
        XCTAssertEqual(cleanup.lastFailure, failure)
        XCTAssertEqual(cleanup.revision, before.revision, "\(failure)")
      }
    }

    try await library.clearManuallyRetryableCloudAttachmentFailures(namespaceKey: namespace)

    let clearedAgain = try await attachmentStorage(library)
    XCTAssertEqual(clearedAgain, cleared)
  }

  func testChangedBytesOfAPublishedAttachmentQueueOneCleanupForTheOldPayloadAfterReopen() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("local.txt")
    try Data("published bytes".utf8).write(to: source)
    let storeURL = root.appendingPathComponent("store")
    let attachmentID: UUID
    let oldPayload: CloudTextStorageIdentity
    do {
      let library = try SwiftDataSnipLibrary(storeURL: storeURL)
      try await addSnip(to: library, attaching: [source])
      try await reconcile(library)
      let pendingStorage = try await attachmentStorage(library)
      let pending = try XCTUnwrap(pendingStorage.publications.first)
      attachmentID = pending.metadata.attachmentID
      oldPayload = pending.metadata.payloadIdentity
      try await commit(library, [.payloadAccepted(
        attachmentID: attachmentID,
        expectedRevision: pending.revision,
        shadowData: Data("old-payload-shadow".utf8),
        systemFields: Data("old-payload-fields".utf8)
      )])
      try await commit(library, [.metadataAccepted(
        attachmentID: attachmentID,
        expectedRevision: pending.revision + 1,
        shadowData: Data("old-metadata-shadow".utf8),
        systemFields: Data("old-metadata-fields".utf8)
      )])
      let publishedStorage = try await attachmentStorage(library)
      let published = try XCTUnwrap(publishedStorage.publications.first)
      XCTAssertTrue(published.metadataAccepted)
      let durableFile = try XCTUnwrap(published.localSourceURL)
      try Data("bytes changed in place after publishing".utf8).write(to: durableFile)

      try await reconcile(library)

      let changedStorage = try await attachmentStorage(library)
      let changed = try XCTUnwrap(changedStorage.publications.first)
      XCTAssertEqual(changed.priorPayloadIdentity, oldPayload)
      XCTAssertEqual(changed.priorPayloadShadowData, Data("old-payload-shadow".utf8))
      XCTAssertNotEqual(changed.metadata.payloadIdentity, oldPayload)
      XCTAssertFalse(changed.payloadAccepted)
      XCTAssertFalse(changed.metadataAccepted)
      XCTAssertNotNil(changed.sourceURL)
      XCTAssertTrue(changedStorage.cleanups.isEmpty)
    }

    let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)
    let reopenedStorage = try await attachmentStorage(reopened)
    let replacement = try XCTUnwrap(reopenedStorage.publications.first)
    XCTAssertEqual(replacement.priorPayloadIdentity, oldPayload)
    try await commit(reopened, [.payloadAccepted(
      attachmentID: attachmentID,
      expectedRevision: replacement.revision,
      shadowData: Data("new-payload-shadow".utf8),
      systemFields: Data("new-payload-fields".utf8)
    )])
    let payloadStorage = try await attachmentStorage(reopened)
    XCTAssertTrue(payloadStorage.cleanups.isEmpty)
    XCTAssertEqual(payloadStorage.publications.first?.priorPayloadIdentity, oldPayload)

    try await commit(reopened, [.metadataAccepted(
      attachmentID: attachmentID,
      expectedRevision: replacement.revision + 1,
      shadowData: Data("new-metadata-shadow".utf8),
      systemFields: Data("new-metadata-fields".utf8)
    )])

    let republishedStorage = try await attachmentStorage(reopened)
    XCTAssertEqual(republishedStorage.cleanups.map(\.identity), [oldPayload])
    XCTAssertEqual(
      republishedStorage.cleanups.first?.shadowData,
      Data("old-payload-shadow".utf8)
    )
    let republished = try XCTUnwrap(republishedStorage.publications.first)
    XCTAssertTrue(republished.metadataAccepted)
    XCTAssertNil(republished.priorPayloadIdentity)
    XCTAssertNil(republished.priorPayloadShadowData)
  }

  func testChangedBytesBeforeFirstMetadataPublishesDeferAcceptedPayloadCleanups() async throws {
    let fixture = try await makeLocalAttachmentFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = fixture.publication
    let attachmentID = pending.metadata.attachmentID
    let oldPayload = pending.metadata.payloadIdentity
    let oldShadow = Data("old-payload-shadow".utf8)
    try await commit(fixture.library, [.payloadAccepted(
      attachmentID: attachmentID,
      expectedRevision: pending.revision,
      shadowData: oldShadow,
      systemFields: Data("old-payload-fields".utf8)
    )])
    let acceptedStorage = try await attachmentStorage(fixture.library)
    let accepted = try XCTUnwrap(acceptedStorage.publications.first)
    XCTAssertTrue(accepted.payloadAccepted)
    XCTAssertFalse(accepted.metadataAccepted)
    let durableFile = try XCTUnwrap(accepted.localSourceURL)
    try Data("bytes changed before the metadata published".utf8).write(to: durableFile)

    try await reconcile(fixture.library)

    let changedStorage = try await attachmentStorage(fixture.library)
    let changed = try XCTUnwrap(changedStorage.publications.first)
    let replacementPayload = changed.metadata.payloadIdentity
    XCTAssertNotEqual(replacementPayload, oldPayload)
    XCTAssertFalse(changed.payloadAccepted)
    XCTAssertNotNil(changed.sourceURL, "The new bytes must queue an upload.")
    XCTAssertEqual(changed.priorPayloadIdentity, oldPayload)
    XCTAssertEqual(changed.priorPayloadShadowData, oldShadow)
    XCTAssertTrue(changedStorage.cleanups.isEmpty, "A first metadata save may already name the old payload.")

    let replacementShadow = Data("replacement-payload-shadow".utf8)
    try await commit(fixture.library, [.payloadAccepted(
      attachmentID: attachmentID,
      expectedRevision: changed.revision,
      shadowData: replacementShadow,
      systemFields: Data()
    )])
    let latestBytes = Data("bytes from a second edit".utf8)
    try latestBytes.write(to: durableFile)
    try await reconcile(fixture.library)

    let latestStorage = try await attachmentStorage(fixture.library)
    let latest = try XCTUnwrap(latestStorage.publications.first)
    XCTAssertNotEqual(latest.metadata.payloadIdentity, replacementPayload)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(latest.sourceURL)), latestBytes)
    XCTAssertEqual(latest.priorPayloadIdentity, oldPayload)
    XCTAssertEqual(latest.priorPayloadShadowData, oldShadow)
    XCTAssertEqual(latestStorage.cleanups.map(\.identity), [replacementPayload])
    let blockedCleanup = try XCTUnwrap(latestStorage.cleanups.first)
    XCTAssertEqual(blockedCleanup.shadowData, replacementShadow)
    XCTAssertEqual(blockedCleanup.blockedByAttachmentID, attachmentID)

    try await commit(fixture.library, [.payloadAccepted(
      attachmentID: attachmentID,
      expectedRevision: latest.revision,
      shadowData: Data("latest-payload-shadow".utf8),
      systemFields: Data()
    )])
    let beforePublish = try await attachmentStorage(fixture.library)
    let uploaded = try XCTUnwrap(beforePublish.publications.first)
    XCTAssertEqual(beforePublish.cleanups, [blockedCleanup])
    XCTAssertEqual(uploaded.priorPayloadIdentity, oldPayload)
    try await commit(fixture.library, [.metadataAccepted(
      attachmentID: attachmentID,
      expectedRevision: uploaded.revision,
      shadowData: Data("latest-metadata-shadow".utf8),
      systemFields: Data()
    )])

    let published = try await attachmentStorage(fixture.library)
    XCTAssertTrue(published.publications.first?.metadataAccepted == true)
    XCTAssertNil(published.publications.first?.priorPayloadIdentity)
    XCTAssertEqual(Set(published.cleanups.map(\.identity)), Set([oldPayload, replacementPayload]))
    let oldCleanup = try XCTUnwrap(published.cleanups.first { $0.identity == oldPayload })
    XCTAssertEqual(oldCleanup.shadowData, oldShadow)
    XCTAssertNil(oldCleanup.blockedByAttachmentID)
  }

  // MARK: Cache install

  func testCacheInstallSaveFailureDiscardsTheStagedFileAndLeavesNoCacheEntry() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let snipID = try await addSnip(to: library)
    let bytes = Data("downloaded once the save works".utf8)
    let metadata = try await acceptRemoteAttachment(
      library,
      snipID: snipID,
      position: 0,
      fileName: "download.txt",
      bytes: bytes
    )
    let filesDirectory = try await cacheFilesDirectory(library, attachmentID: metadata.attachmentID)
    let failing = try failingLibrary(storeURL: storeURL)
    let staged = try await stageDownload(bytes, in: failing)

    do {
      _ = try await installDownload(metadata, bytes: bytes, staged: staged, in: failing)
      XCTFail("The injected save failure must abort the cache install.")
    } catch is InjectedSaveFailure {}

    XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    XCTAssertEqual(regularFileNames(under: filesDirectory), [])
    let afterFailure = try await attachmentStorage(library)
    XCTAssertTrue(afterFailure.cacheEntries.isEmpty)
    let unavailable = try await storedAttachment(library, metadata.attachmentID)
    XCTAssertNil(unavailable.url)

    let retryStaged = try await stageDownload(bytes, in: library)
    let installed = try await installDownload(
      metadata,
      bytes: bytes,
      staged: retryStaged,
      in: library
    )

    XCTAssertEqual(try Data(contentsOf: installed), bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: retryStaged.path))
    XCTAssertEqual(regularFileNames(under: filesDirectory), [installed.lastPathComponent])
    let afterRetry = try await attachmentStorage(library)
    XCTAssertEqual(afterRetry.cacheEntries.map(\.attachmentID), [metadata.attachmentID])
    let available = try await storedAttachment(library, metadata.attachmentID)
    XCTAssertEqual(available.url?.path, installed.path)
  }

  func testCacheInstallKeepsOnlyTheNewestDownloadAndEvictsOlderEntries() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let snipID = try await addSnip(to: library)
    let olderBytes = Data("older and larger cached attachment".utf8)
    let newerBytes = Data("newer attachment".utf8)
    XCTAssertGreaterThan(olderBytes.count, newerBytes.count)
    let older = try await acceptRemoteAttachment(
      library,
      snipID: snipID,
      position: 0,
      fileName: "older.txt",
      bytes: olderBytes
    )
    let newer = try await acceptRemoteAttachment(
      library,
      snipID: snipID,
      position: 1,
      fileName: "newer.txt",
      bytes: newerBytes
    )
    let olderFiles = try await cacheFilesDirectory(library, attachmentID: older.attachmentID)
    let firstStaged = try await stageDownload(olderBytes, in: library)
    let firstDownload = try await installDownload(
      older,
      bytes: olderBytes,
      staged: firstStaged,
      in: library,
      now: Date(timeIntervalSince1970: 1)
    )
    let secondStaged = try await stageDownload(olderBytes, in: library)

    let secondDownload = try await installDownload(
      older,
      bytes: olderBytes,
      staged: secondStaged,
      in: library,
      now: Date(timeIntervalSince1970: 2)
    )

    XCTAssertNotEqual(firstDownload.path, secondDownload.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstDownload.path))
    XCTAssertEqual(try Data(contentsOf: secondDownload), olderBytes)
    XCTAssertEqual(regularFileNames(under: olderFiles), [secondDownload.lastPathComponent])
    let reinstalled = try await attachmentStorage(library)
    XCTAssertEqual(reinstalled.cacheEntries.map(\.attachmentID), [older.attachmentID])
    XCTAssertEqual(reinstalled.cacheEntries.first?.fileURL.path, secondDownload.path)

    let newerStaged = try await stageDownload(newerBytes, in: library)
    let newerDownload = try await installDownload(
      newer,
      bytes: newerBytes,
      staged: newerStaged,
      in: library,
      maximumBytes: Int64(newerBytes.count),
      now: Date(timeIntervalSince1970: 3)
    )

    XCTAssertEqual(try Data(contentsOf: newerDownload), newerBytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: secondDownload.path))
    XCTAssertEqual(regularFileNames(under: olderFiles), [])
    let evicted = try await attachmentStorage(library)
    XCTAssertEqual(evicted.cacheEntries.map(\.attachmentID), [newer.attachmentID])
    XCTAssertEqual(
      Set(evicted.publications.map(\.metadata.attachmentID)),
      [older.attachmentID, newer.attachmentID]
    )
  }

  // MARK: Durable copy

  func testDurableCopySaveFailureRollsBackAndALaterCopyIsKeptOnce() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let snipID = try await addSnip(to: library)
    let bytes = Data("downloaded bytes kept for a local copy".utf8)
    let metadata = try await acceptRemoteAttachment(
      library,
      snipID: snipID,
      position: 0,
      fileName: "kept.txt",
      bytes: bytes
    )
    let staged = try await stageDownload(bytes, in: library)
    let cachedURL = try await installDownload(metadata, bytes: bytes, staged: staged, in: library)
    let durableURL = durableCopyURL(storeURL: storeURL, metadata: metadata)
    let failing = try failingLibrary(storeURL: storeURL)

    do {
      _ = try await failing.materializeCloudAttachmentForLocalCopy(
        namespaceKey: namespace,
        attachmentID: metadata.attachmentID
      )
      XCTFail("The injected save failure must abort the durable copy.")
    } catch is InjectedSaveFailure {}

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: durableURL.deletingLastPathComponent().path)
    )
    let rolledBack = try await storedAttachment(library, metadata.attachmentID)
    XCTAssertTrue(rolledBack.attachment.relativePath.hasPrefix("CloudDownloads/"))
    XCTAssertEqual(try Data(contentsOf: cachedURL), bytes)

    let copied = try await library.materializeCloudAttachmentForLocalCopy(
      namespaceKey: namespace,
      attachmentID: metadata.attachmentID
    )

    XCTAssertTrue(copied)
    let durable = try await storedAttachment(library, metadata.attachmentID)
    XCTAssertFalse(durable.attachment.relativePath.hasPrefix("CloudDownloads/"))
    XCTAssertEqual(durable.url?.path, durableURL.path)
    XCTAssertEqual(try Data(contentsOf: durableURL), bytes)
    let storageAfterCopy = try await attachmentStorage(library)

    let copiedAgain = try await library.materializeCloudAttachmentForLocalCopy(
      namespaceKey: namespace,
      attachmentID: metadata.attachmentID
    )

    XCTAssertTrue(copiedAgain)
    let unchanged = try await storedAttachment(library, metadata.attachmentID)
    XCTAssertEqual(unchanged.attachment, durable.attachment)
    XCTAssertEqual(try Data(contentsOf: durableURL), bytes)
    let storageAfterSecondCopy = try await attachmentStorage(library)
    XCTAssertEqual(storageAfterSecondCopy, storageAfterCopy)
  }

  func testICloudDataResetSaveFailureRollsBackDurableCopiesAndKeepsPublications() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let snipID = try await addSnip(to: library)
    let firstBytes = Data("first downloaded attachment".utf8)
    let secondBytes = Data("second downloaded attachment".utf8)
    let first = try await acceptRemoteAttachment(
      library,
      snipID: snipID,
      position: 0,
      fileName: "first.txt",
      bytes: firstBytes
    )
    let second = try await acceptRemoteAttachment(
      library,
      snipID: snipID,
      position: 1,
      fileName: "second.txt",
      bytes: secondBytes
    )
    let firstStaged = try await stageDownload(firstBytes, in: library)
    let firstCache = try await installDownload(
      first,
      bytes: firstBytes,
      staged: firstStaged,
      in: library
    )
    let secondStaged = try await stageDownload(secondBytes, in: library)
    let secondCache = try await installDownload(
      second,
      bytes: secondBytes,
      staged: secondStaged,
      in: library
    )
    let removedRemotely = try await acceptRemoteAttachment(
      library,
      snipID: UUID(),
      position: 0,
      fileName: "removed.txt",
      bytes: Data("removed on another device".utf8)
    )
    try await commit(library, [.remoteMetadataDeleted(
      metadataIdentity: remoteMetadataIdentity(for: removedRemotely.attachmentID)
    )])
    let before = try await attachmentStorage(library)
    XCTAssertEqual(before.publications.count, 2)
    XCTAssertEqual(before.cleanups.count, 1)
    XCTAssertEqual(before.cacheEntries.count, 2)
    let failing = try failingLibrary(storeURL: storeURL)

    do {
      try await failing.promoteAvailableCloudAttachments(namespaceKey: namespace)
      XCTFail("The injected save failure must abort iCloud data reset recovery.")
    } catch is InjectedSaveFailure {}

    let afterFailure = try await attachmentStorage(library)
    XCTAssertEqual(afterFailure, before)
    for metadata in [first, second] {
      let durableDirectory = durableCopyURL(storeURL: storeURL, metadata: metadata)
        .deletingLastPathComponent()
      XCTAssertFalse(FileManager.default.fileExists(atPath: durableDirectory.path))
      let rolledBack = try await storedAttachment(library, metadata.attachmentID)
      XCTAssertTrue(rolledBack.attachment.relativePath.hasPrefix("CloudDownloads/"))
    }
    XCTAssertEqual(try Data(contentsOf: firstCache), firstBytes)
    XCTAssertEqual(try Data(contentsOf: secondCache), secondBytes)

    try await library.promoteAvailableCloudAttachments(namespaceKey: namespace)

    try await library.clearCloudSyncState(namespaceKey: namespace, afterReset: true)
    let isolated = try await attachmentStorage(library)
    XCTAssertTrue(isolated.publications.isEmpty)
    XCTAssertTrue(isolated.cleanups.isEmpty)
    XCTAssertTrue(isolated.cacheEntries.isEmpty)
    for (metadata, bytes) in [(first, firstBytes), (second, secondBytes)] {
      let kept = try await storedAttachment(library, metadata.attachmentID)
      XCTAssertFalse(kept.attachment.relativePath.hasPrefix("CloudDownloads/"))
      let keptURL = try XCTUnwrap(kept.url)
      XCTAssertEqual(keptURL.path, durableCopyURL(storeURL: storeURL, metadata: metadata).path)
      XCTAssertEqual(try Data(contentsOf: keptURL), bytes)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstCache.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: secondCache.path))
  }

  // MARK: Downloads while metadata waits to sync

  // CloudKit holds each payload below while its metadata waits to sync, so each case fails if
  // its reader goes back to requiring accepted metadata.

  func testTouchKeepsAVerifiedDownloadWhileTheMetadataWaitsToSync() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let bytes = Data("download touched while its metadata waits".utf8)
    let download = try await makeDownloadAwaitingMetadata(in: library, bytes: bytes)
    let touchedAt = Date(timeIntervalSince1970: 10)

    let touched = try await library.touchCloudAttachmentCache(
      namespaceKey: namespace,
      attachmentID: download.metadata.attachmentID,
      now: touchedAt
    )

    XCTAssertEqual(
      touched?.standardizedFileURL,
      download.cachedURL.standardizedFileURL,
      "Touch must return the verified download."
    )
    XCTAssertEqual(
      try? Data(contentsOf: download.cachedURL),
      bytes,
      "Touch must keep the cached bytes."
    )
    let storage = try await attachmentStorage(library)
    XCTAssertEqual(
      storage.cacheEntries.map(\.attachmentID),
      [download.metadata.attachmentID],
      "Touch must keep the cache entry."
    )
    XCTAssertEqual(
      storage.cacheEntries.first?.lastAccessedAt,
      touchedAt,
      "Touch must record the access."
    )
  }

  func testSweepKeepsAVerifiedDownloadWhileTheMetadataWaitsToSync() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let bytes = Data("download swept while its metadata waits".utf8)
    let download = try await makeDownloadAwaitingMetadata(in: library, bytes: bytes)

    try await library.sweepCloudAttachmentCache(namespaceKey: namespace, maximumBytes: 1_024)

    XCTAssertEqual(
      try? Data(contentsOf: download.cachedURL),
      bytes,
      "The sweep must keep the cached file."
    )
    let storage = try await attachmentStorage(library)
    XCTAssertEqual(
      storage.cacheEntries.map(\.attachmentID),
      [download.metadata.attachmentID],
      "The sweep must keep the cache entry."
    )
  }

  func testDurableCopyRecoversAnInvalidDurableFileWhileTheMetadataWaitsToSync() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let bytes = Data("durable copy damaged while its metadata waits".utf8)
    let download = try await makeDownloadAwaitingMetadata(in: library, bytes: bytes)
    let attachmentID = download.metadata.attachmentID
    let copied = try await library.materializeCloudAttachmentForLocalCopy(
      namespaceKey: namespace,
      attachmentID: attachmentID
    )
    XCTAssertTrue(copied, "The verified download must become the durable copy.")
    let durable = try await storedAttachment(library, attachmentID)
    XCTAssertFalse(
      durable.attachment.relativePath.hasPrefix("CloudDownloads/"),
      "The attachment must now point at its durable copy."
    )
    let durableURL = durableCopyURL(storeURL: storeURL, metadata: download.metadata)
    try FileManager.default.removeItem(at: durableURL)
    try Data(repeating: 0xA5, count: bytes.count).write(to: durableURL)

    await assertDurableCopyDefersToCloudKit(
      library,
      attachmentID,
      "An invalid durable file must be recoverable from CloudKit"
    )
  }

  func testDurableCopyRecoversAnUnresolvableCachePathWhileTheMetadataWaitsToSync() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let bytes = Data("cache path broken while its metadata waits".utf8)
    let download = try await makeDownloadAwaitingMetadata(in: library, bytes: bytes)
    let elsewhere = root.appendingPathComponent("elsewhere.txt")
    try bytes.write(to: elsewhere)
    try FileManager.default.removeItem(at: download.cachedURL)
    try FileManager.default.createSymbolicLink(
      at: download.cachedURL,
      withDestinationURL: elsewhere
    )

    await assertDurableCopyDefersToCloudKit(
      library,
      download.metadata.attachmentID,
      "A cache path that doesn't resolve must be recoverable from CloudKit"
    )

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: durableCopyURL(storeURL: storeURL, metadata: download.metadata).path
      ),
      "The durable copy must not follow the link."
    )
  }

  func testDurableCopyRecoversCorruptCachedBytesWhileTheMetadataWaitsToSync() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let bytes = Data("cached bytes corrupted while its metadata waits".utf8)
    let download = try await makeDownloadAwaitingMetadata(in: library, bytes: bytes)
    try Data(repeating: 0xA5, count: bytes.count).write(to: download.cachedURL)

    await assertDurableCopyDefersToCloudKit(
      library,
      download.metadata.attachmentID,
      "Corrupt cached bytes must be recoverable from CloudKit"
    )

    let stored = try await storedAttachment(library, download.metadata.attachmentID)
    XCTAssertTrue(
      stored.attachment.relativePath.hasPrefix("CloudDownloads/"),
      "Corrupt cached bytes must not become the durable copy."
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: durableCopyURL(storeURL: storeURL, metadata: download.metadata).path
      ),
      "Corrupt cached bytes must not be copied."
    )
  }

  // MARK: Defect regressions

  // DC1: a copy killed midway leaves a partial file at the durable destination. No stored
  // attachment references it, so after a restart it must not block keeping a local copy
  // (opt-out and account isolation's Keep Local Copy both prepare this way).
  func testInterruptedDurableCopyDoesNotBlockKeepingALocalCopyAfterRestart() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    let bytes = Data("bytes an interrupted durable copy only half wrote".utf8)
    let metadata: CloudAttachmentMetadataValue
    do {
      let library = try SwiftDataSnipLibrary(storeURL: storeURL)
      metadata = try await makeDownloadedAttachment(
        in: library,
        fileName: "interrupted.txt",
        bytes: bytes
      )
    }
    let durableURL = durableCopyURL(storeURL: storeURL, metadata: metadata)
    try seedInterruptedDurableCopy(at: durableURL, bytes: bytes)
    let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)

    do {
      try await reopened.prepareCloudAttachmentsForLocalCopy(namespaceKey: namespace)
    } catch {
      return XCTFail(
        "A partial file from an interrupted durable copy must not block keeping a local copy: \(error)"
      )
    }

    XCTAssertEqual(try Data(contentsOf: durableURL), bytes)
    let durable = try await storedAttachment(reopened, metadata.attachmentID)
    XCTAssertEqual(durable.url?.path, durableURL.path)
  }

  // DC1 through iCloud data reset recovery, which makes the same durable copy before it
  // clears the namespace.
  func testInterruptedDurableCopyDoesNotBlockICloudDataResetRecoveryAfterRestart() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    let bytes = Data("bytes an interrupted durable copy only half wrote".utf8)
    let metadata: CloudAttachmentMetadataValue
    do {
      let library = try SwiftDataSnipLibrary(storeURL: storeURL)
      metadata = try await makeDownloadedAttachment(
        in: library,
        fileName: "interrupted.txt",
        bytes: bytes
      )
    }
    let durableURL = durableCopyURL(storeURL: storeURL, metadata: metadata)
    try seedInterruptedDurableCopy(at: durableURL, bytes: bytes)
    let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)

    do {
      try await reopened.promoteAvailableCloudAttachments(namespaceKey: namespace)
      try await reopened.clearCloudSyncState(namespaceKey: namespace, afterReset: true)
    } catch {
      return XCTFail(
        "A partial file from an interrupted durable copy must not block iCloud data reset recovery: \(error)"
      )
    }

    XCTAssertEqual(try Data(contentsOf: durableURL), bytes)
    let durable = try await storedAttachment(reopened, metadata.attachmentID)
    XCTAssertEqual(durable.url?.path, durableURL.path)
    let recovered = try await attachmentStorage(reopened)
    XCTAssertTrue(recovered.publications.isEmpty)
  }

  // Guard for the DC1 fix: an invalid file that a stored attachment references holds that
  // attachment's bytes, so the durable copy must still refuse and leave it alone.
  func testDurableCopyRefusesAnInvalidDestinationThatAnotherAttachmentReferences() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let bytes = Data("downloaded bytes that must not replace another attachment".utf8)
    let metadata = try await makeDownloadedAttachment(
      in: library,
      fileName: "shared.txt",
      bytes: bytes
    )
    let durableURL = durableCopyURL(storeURL: storeURL, metadata: metadata)
    let referencedBytes = Data("bytes another attachment owns".utf8)
    try FileManager.default.createDirectory(
      at: durableURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try referencedBytes.write(to: durableURL)
    let referencingID = UUID()
    _ = try await library.perform(
      .restore(snips: [Snip(
        content: "references the durable destination",
        origin: .quickEntry,
        attachments: [SnipAttachment(
          id: referencingID,
          fileName: metadata.fileName,
          relativePath: "\(metadata.attachmentID.uuidString)/\(metadata.fileName)",
          contentType: "text/plain",
          byteCount: Int64(referencedBytes.count)
        )]
      )]),
      sortedBy: .manual
    )
    let referencing = try await storedAttachment(library, referencingID)
    XCTAssertEqual(referencing.url?.path, durableURL.path)
    let before = try await attachmentStorage(library)

    do {
      _ = try await library.materializeCloudAttachmentForLocalCopy(
        namespaceKey: namespace,
        attachmentID: metadata.attachmentID
      )
      XCTFail("The durable copy must not replace bytes another attachment references.")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .attachmentCopyFailed)
    }

    XCTAssertEqual(try Data(contentsOf: durableURL), referencedBytes)
    let downloaded = try await storedAttachment(library, metadata.attachmentID)
    XCTAssertTrue(downloaded.attachment.relativePath.hasPrefix("CloudDownloads/"))

    do {
      try await library.promoteAvailableCloudAttachments(namespaceKey: namespace)
      XCTFail("iCloud data reset recovery must not replace bytes another attachment references.")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .attachmentCopyFailed)
    }

    XCTAssertEqual(try Data(contentsOf: durableURL), referencedBytes)
    let afterRecovery = try await attachmentStorage(library)
    XCTAssertEqual(afterRecovery, before)
  }

  // Guard for the DC1 fix: on a case-insensitive volume, a stored path that differs only in
  // letter case names the same file. The check compares strings, so it refuses on any volume.
  func testDurableCopyRefusesADestinationReferencedInAnotherLetterCase() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let bytes = Data("downloaded bytes that must not replace a differently cased reference".utf8)
    let metadata = try await makeDownloadedAttachment(
      in: library,
      fileName: "shared.txt",
      bytes: bytes
    )
    let destinationPath = "\(metadata.attachmentID.uuidString)/\(metadata.fileName)"
    let referencePath = destinationPath.uppercased()
    XCTAssertNotEqual(referencePath, destinationPath)
    let referencedBytes = Data("bytes another attachment owns".utf8)
    let referencingID = UUID()
    _ = try await library.perform(
      .restore(snips: [Snip(
        content: "references the durable destination in another letter case",
        origin: .quickEntry,
        attachments: [SnipAttachment(
          id: referencingID,
          fileName: metadata.fileName,
          relativePath: referencePath,
          contentType: "text/plain",
          byteCount: Int64(referencedBytes.count)
        )]
      )]),
      sortedBy: .manual
    )
    let referencing = try await storedAttachment(library, referencingID)
    XCTAssertEqual(referencing.attachment.relativePath, referencePath)
    let durableURL = durableCopyURL(storeURL: storeURL, metadata: metadata)
    try FileManager.default.createDirectory(
      at: durableURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try referencedBytes.write(to: durableURL)
    let before = try await attachmentStorage(library)

    do {
      _ = try await library.materializeCloudAttachmentForLocalCopy(
        namespaceKey: namespace,
        attachmentID: metadata.attachmentID
      )
      XCTFail("The durable copy must not replace a differently cased reference.")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .attachmentCopyFailed)
    }

    XCTAssertEqual(try Data(contentsOf: durableURL), referencedBytes)
    let downloaded = try await storedAttachment(library, metadata.attachmentID)
    XCTAssertTrue(downloaded.attachment.relativePath.hasPrefix("CloudDownloads/"))

    do {
      try await library.promoteAvailableCloudAttachments(namespaceKey: namespace)
      XCTFail("iCloud data reset recovery must not replace a differently cased reference.")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .attachmentCopyFailed)
    }

    XCTAssertEqual(try Data(contentsOf: durableURL), referencedBytes)
    let afterRecovery = try await attachmentStorage(library)
    XCTAssertEqual(afterRecovery, before)
  }

  // DC2 invariant: an accepted payload releases its queued upload copy. Adopting remote
  // metadata whose hash matches the local bytes is the path that skips this today.
  func testAcceptedPayloadReleasesItsQueuedUploadCopy() async throws {
    let fixture = try await makeLocalAttachmentFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = fixture.publication
    let queuedUpload = try XCTUnwrap(pending.sourceURL)
    let remotePayload = CloudTextStorageIdentity(
      zoneName: "payload",
      ownerName: "owner",
      recordName: UUID().uuidString.lowercased()
    )
    XCTAssertNotEqual(remotePayload, pending.metadata.payloadIdentity)
    try await commit(fixture.library, [.remoteMetadataAccepted(
      metadata: CloudAttachmentMetadataValue(
        attachmentID: pending.metadata.attachmentID,
        snipID: pending.metadata.snipID,
        position: pending.metadata.position,
        fileName: pending.metadata.fileName,
        contentType: pending.metadata.contentType,
        byteCount: pending.metadata.byteCount,
        sha256: pending.metadata.sha256,
        payloadIdentity: remotePayload
      ),
      metadataIdentity: pending.metadataIdentity,
      shadowData: Data("remote-metadata-shadow".utf8),
      systemFields: Data("remote-metadata-fields".utf8)
    )])

    try await reconcile(fixture.library)

    let adoptedStorage = try await attachmentStorage(fixture.library)
    let adopted = try XCTUnwrap(adoptedStorage.publications.first)
    XCTAssertEqual(adopted.metadata.payloadIdentity, remotePayload)
    XCTAssertTrue(adopted.payloadAccepted)
    XCTAssertTrue(adopted.metadataAccepted)
    XCTAssertNotNil(adopted.localSourceURL)
    XCTAssertNil(adopted.sourceURL, "An accepted payload must not keep a queued upload.")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: queuedUpload.deletingLastPathComponent().path),
      "The queued upload copy must not outlive the payload's acceptance."
    )
  }

  // MARK: Helpers

  private var namespace: CloudSyncNamespaceKey {
    CloudSyncNamespaceKey(rawValue: "attachment-lifecycle")
  }

  private func publishLocalAttachment(_ fixture: LocalAttachmentFixture) async throws -> CloudAttachmentPublication {
    let pending = fixture.publication
    try await commit(fixture.library, [.payloadAccepted(
      attachmentID: pending.metadata.attachmentID,
      expectedRevision: pending.revision,
      shadowData: Data("published-payload-shadow".utf8),
      systemFields: Data()
    )])
    let payloadStorage = try await attachmentStorage(fixture.library)
    let payload = try XCTUnwrap(payloadStorage.publications.first, "Accepting the payload must keep its publication.")
    try await commit(fixture.library, [.metadataAccepted(
      attachmentID: payload.metadata.attachmentID,
      expectedRevision: payload.revision,
      shadowData: Data("published-metadata-shadow".utf8),
      systemFields: Data()
    )])
    let publishedStorage = try await attachmentStorage(fixture.library)
    return try XCTUnwrap(publishedStorage.publications.first, "Accepting metadata must keep its publication.")
  }

  private func replaceFixtureFile(_ fixture: LocalAttachmentFixture) async throws {
    let storage = try await attachmentStorage(fixture.library)
    let publication = try XCTUnwrap(storage.publications.first, "The fixture must keep its publication.")
    let source = try XCTUnwrap(publication.localSourceURL, "The fixture must retain its durable file.")
    try Data("replacement file bytes".utf8).write(to: source)
    try await reconcile(fixture.library)
  }

  private func makeLocalAttachmentFixture() async throws -> LocalAttachmentFixture {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("local.txt")
    try Data("local attachment bytes".utf8).write(to: source)
    let storeURL = root.appendingPathComponent("store")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let snipID = try await addSnip(to: library, attaching: [source])
    try await reconcile(library)
    let pendingStorage = try await attachmentStorage(library)
    let publication = try XCTUnwrap(pendingStorage.publications.first)
    return LocalAttachmentFixture(
      root: root,
      storeURL: storeURL,
      library: library,
      snipID: snipID,
      publication: publication
    )
  }

  @discardableResult
  private func addSnip(
    to library: SwiftDataSnipLibrary,
    attaching sources: [URL] = []
  ) async throws -> UUID {
    let update = try await library.perform(
      .add(
        content: "attachment lifecycle",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: sources,
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = update.outcome else {
      throw LifecycleFixtureError.missingSnip
    }
    return snipID
  }

  private func failingLibrary(storeURL: URL) throws -> SwiftDataSnipLibrary {
    try SwiftDataSnipLibrary(
      storeURL: storeURL,
      afterMutationBeforeSave: { throw InjectedSaveFailure.beforeSave }
    )
  }

  private func reconcile(_ library: SwiftDataSnipLibrary) async throws {
    try await library.reconcileCloudAttachments(
      namespaceKey: namespace,
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
  }

  private func commit(
    _ library: SwiftDataSnipLibrary,
    _ transitions: [CloudAttachmentTransition]
  ) async throws {
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace,
      transitions: transitions
    )
  }

  private func attachmentStorage(
    _ library: SwiftDataSnipLibrary
  ) async throws -> CloudAttachmentStorageSnapshot {
    try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace)
  }

  private func assertStaleTransition(
    _ library: SwiftDataSnipLibrary,
    _ transition: CloudAttachmentTransition,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let before = try await attachmentStorage(library)
    do {
      try await commit(library, [transition])
      XCTFail("Expected a stale transition: \(transition)", file: file, line: line)
    } catch {
      XCTAssertEqual(
        error as? CloudAttachmentStorageError,
        .staleTransition,
        file: file,
        line: line
      )
    }
    let after = try await attachmentStorage(library)
    XCTAssertEqual(after, before, file: file, line: line)
  }

  private func remoteMetadataIdentity(for attachmentID: UUID) -> CloudTextStorageIdentity {
    CloudTextStorageIdentity(
      zoneName: "data",
      ownerName: "owner",
      recordName: "a-\(attachmentID.uuidString.lowercased())"
    )
  }

  /// Commits remote metadata the way a fetch does, so the attachment appears on its snip
  /// with a `CloudDownloads` path and no local bytes.
  private func acceptRemoteAttachment(
    _ library: SwiftDataSnipLibrary,
    snipID: UUID,
    position: Int,
    fileName: String,
    bytes: Data
  ) async throws -> CloudAttachmentMetadataValue {
    let attachmentID = UUID()
    let metadata = CloudAttachmentMetadataValue(
      attachmentID: attachmentID,
      snipID: snipID,
      position: position,
      fileName: fileName,
      contentType: "text/plain",
      byteCount: Int64(bytes.count),
      sha256: Data(SHA256.hash(data: bytes)),
      payloadIdentity: CloudTextStorageIdentity(
        zoneName: "payload",
        ownerName: "owner",
        recordName: UUID().uuidString.lowercased()
      )
    )
    try await commit(library, [.remoteMetadataAccepted(
      metadata: metadata,
      metadataIdentity: remoteMetadataIdentity(for: attachmentID),
      shadowData: Data("metadata-shadow".utf8),
      systemFields: Data("metadata-fields".utf8)
    )])
    return metadata
  }

  /// A snip whose only attachment is a remote one with verified bytes in the download cache.
  private func makeDownloadedAttachment(
    in library: SwiftDataSnipLibrary,
    fileName: String,
    bytes: Data
  ) async throws -> CloudAttachmentMetadataValue {
    let snipID = try await addSnip(to: library)
    let metadata = try await acceptRemoteAttachment(
      library,
      snipID: snipID,
      position: 0,
      fileName: fileName,
      bytes: bytes
    )
    let staged = try await stageDownload(bytes, in: library)
    _ = try await installDownload(metadata, bytes: bytes, staged: staged, in: library)
    let downloaded = try await storedAttachment(library, metadata.attachmentID)
    XCTAssertTrue(downloaded.attachment.relativePath.hasPrefix("CloudDownloads/"))
    return metadata
  }

  /// A remote attachment with verified bytes in the download cache whose metadata save then
  /// conflicted, so CloudKit holds its payload while its metadata waits to sync.
  private func makeDownloadAwaitingMetadata(
    in library: SwiftDataSnipLibrary,
    bytes: Data
  ) async throws -> (metadata: CloudAttachmentMetadataValue, cachedURL: URL) {
    let snipID = try await addSnip(to: library)
    let metadata = try await acceptRemoteAttachment(
      library,
      snipID: snipID,
      position: 0,
      fileName: "pending.txt",
      bytes: bytes
    )
    let staged = try await stageDownload(bytes, in: library)
    let cachedURL = try await installDownload(metadata, bytes: bytes, staged: staged, in: library)
    let published = try await attachmentStorage(library)
    let revision = try XCTUnwrap(published.publications.first(where: {
      $0.metadata.attachmentID == metadata.attachmentID
    })).revision
    try await commit(library, [.metadataConflict(
      attachmentID: metadata.attachmentID,
      expectedRevision: revision,
      shadowData: Data("conflicting-metadata-shadow".utf8),
      systemFields: Data("conflicting-metadata-fields".utf8)
    )])
    let pending = try await attachmentStorage(library)
    let publication = try XCTUnwrap(pending.publications.first(where: {
      $0.metadata.attachmentID == metadata.attachmentID
    }))
    XCTAssertTrue(publication.payloadAccepted, "CloudKit must hold the payload.")
    XCTAssertFalse(publication.metadataAccepted, "The metadata must wait to sync.")
    XCTAssertNil(publication.localSourceURL, "This device must hold only the download.")
    XCTAssertEqual(pending.cacheEntries.count, 1, "The download must stay cached.")
    return (metadata, cachedURL)
  }

  /// Asserts that the durable copy reports bytes it can't use here as recoverable from CloudKit
  /// instead of failing.
  private func assertDurableCopyDefersToCloudKit(
    _ library: SwiftDataSnipLibrary,
    _ attachmentID: UUID,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      let ready = try await library.materializeCloudAttachmentForLocalCopy(
        namespaceKey: namespace,
        attachmentID: attachmentID
      )
      XCTAssertFalse(ready, "\(message).", file: file, line: line)
    } catch {
      XCTFail("\(message): \(error)", file: file, line: line)
    }
  }

  private func stageDownload(_ bytes: Data, in library: SwiftDataSnipLibrary) async throws -> URL {
    let stagingRoot = try await library.cloudAttachmentStagingRoot(namespaceKey: namespace)
    let staged = stagingRoot.appendingPathComponent("\(UUID().uuidString.lowercased())/payload")
    try FileManager.default.createDirectory(
      at: staged.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try bytes.write(to: staged)
    return staged
  }

  private func installDownload(
    _ metadata: CloudAttachmentMetadataValue,
    bytes: Data,
    staged: URL,
    in library: SwiftDataSnipLibrary,
    maximumBytes: Int64 = 1_024,
    now: Date = .distantPast
  ) async throws -> URL {
    try await library.installCloudAttachmentDownload(
      namespaceKey: namespace,
      attachmentID: metadata.attachmentID,
      expectedPayloadIdentity: metadata.payloadIdentity,
      expectedField: "asset",
      download: CloudAttachmentCacheDownload(
        payloadIdentity: metadata.payloadIdentity,
        field: "asset",
        fileURL: staged,
        byteCount: Int64(bytes.count),
        sha256: Data(SHA256.hash(data: bytes))
      ),
      maximumBytes: maximumBytes,
      now: now
    )
  }

  private func storedAttachment(
    _ library: SwiftDataSnipLibrary,
    _ attachmentID: UUID
  ) async throws -> (attachment: SnipAttachment, url: URL?) {
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let attachment = try XCTUnwrap(
      local.snips.flatMap(\.attachments).first(where: { $0.id == attachmentID })
    )
    return (attachment, local.attachmentURLs[attachmentID])
  }

  /// The cache directory that holds an attachment's installed download files.
  private func cacheFilesDirectory(
    _ library: SwiftDataSnipLibrary,
    attachmentID: UUID
  ) async throws -> URL {
    try await library.cloudAttachmentStagingRoot(namespaceKey: namespace)
      .deletingLastPathComponent()
      .appendingPathComponent("Files", isDirectory: true)
      .appendingPathComponent(attachmentID.uuidString.lowercased(), isDirectory: true)
  }

  /// The durable destination rule in `copyCloudAttachmentToDurableStorage`.
  private func durableCopyURL(storeURL: URL, metadata: CloudAttachmentMetadataValue) -> URL {
    SwiftDataSnipLibrary.attachmentRootURL(forStoreURL: storeURL)
      .appendingPathComponent(metadata.attachmentID.uuidString, isDirectory: true)
      .appendingPathComponent(metadata.fileName, isDirectory: false)
  }

  private func seedInterruptedDurableCopy(at url: URL, bytes: Data) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try bytes.prefix(bytes.count / 2).write(to: url)
  }

  private func uploadDirectoryNames(root: URL) -> [String] {
    let uploadRoot = root
      .appendingPathComponent("CloudAttachmentUploads", isDirectory: true)
      .appendingPathComponent(
        CloudAttachmentCacheFiles.namespaceDigest(namespace.rawValue),
        isDirectory: true
      )
    return ((try? FileManager.default.contentsOfDirectory(atPath: uploadRoot.path)) ?? []).sorted()
  }

  private func regularFileNames(under directory: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey]
    ) else { return [] }
    var names: [String] = []
    for case let url as URL in enumerator
    where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
      names.append(url.lastPathComponent)
    }
    return names.sorted()
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudAttachmentLifecycleTests-\(UUID().uuidString)", isDirectory: true)
  }
}

private enum InjectedSaveFailure: Error {
  case beforeSave
}

private enum LifecycleFixtureError: Error {
  case missingSnip
}

private struct LocalAttachmentFixture {
  let root: URL
  let storeURL: URL
  let library: SwiftDataSnipLibrary
  let snipID: UUID
  let publication: CloudAttachmentPublication
}
