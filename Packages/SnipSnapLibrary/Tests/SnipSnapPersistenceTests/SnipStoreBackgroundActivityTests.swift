import Darwin
import Foundation
import Synchronization
import XCTest

@testable import SnipSnapPersistence
@testable import SnipSnapCore

final class TestStoreActivity: Sendable {
  private let callback = Mutex<(@Sendable () -> Void)?>(nil)
  let started = DispatchSemaphore(value: 0)
  let ended = DispatchSemaphore(value: 0)
  let deny: Bool
  let onEnd: @Sendable () -> Void

  init(deny: Bool = false, onEnd: @escaping @Sendable () -> Void = {}) {
    self.deny = deny
    self.onEnd = onEnd
  }

  var runner: SnipStoreBackgroundActivity.Runner {
    { [self] body in
      callback.withLock { $0 = body }
      started.signal()
      if deny { body() }
      return { [self] in onEnd(); ended.signal() }
    }
  }

  func expire() {
    guard let body = callback.withLock({ $0 }) else { return }
    body()
  }
}

final class SnipStoreBackgroundActivityTests: XCTestCase {
  func testStoreLockRequestsTimeAndEndsItOnlyAfterUnlocking() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let activity = TestStoreActivity(onEnd: {
      let fd = Darwin.open(url.path, O_RDWR)
      defer { Darwin.close(fd) }
      XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "Unlock before ending background time")
      flock(fd, LOCK_UN)
    })
    try SnipStoreBackgroundActivity.$runner.withValue(activity.runner) {
      let lock = try SnipStoreFileLock(url: url)
      defer { withExtendedLifetime(lock) {} }
      XCTAssertEqual(activity.started.wait(timeout: .now() + 1), .success)
      XCTAssertEqual(activity.ended.wait(timeout: .now()), .timedOut)
      let fd = Darwin.open(url.path, O_RDWR)
      defer { Darwin.close(fd) }
      XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), -1)
    }
    XCTAssertEqual(activity.ended.wait(timeout: .now() + 1), .success)
    let fd = Darwin.open(url.path, O_RDWR)
    defer { Darwin.close(fd) }
    XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    flock(fd, LOCK_UN)
  }

  func testDeniedTimeDoesNotOpenTheStoreLock() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let activity = TestStoreActivity(deny: true)
    try SnipStoreBackgroundActivity.$runner.withValue(activity.runner) {
      XCTAssertThrowsError(try SnipStoreFileLock(url: url)) {
        XCTAssertTrue($0 is CancellationError)
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(activity.ended.wait(timeout: .now() + 1), .success)
  }
}

extension CloudFullRecordPersistenceTests {
  func testExpiredBackgroundCommitRollsBackAndReplaysStagedBatch() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let activity = TestStoreActivity()
    let store = try SwiftDataSnipLibrary(
      storeURL: location.store,
      afterMutationBeforeSave: { activity.expire() }
    )
    let namespace = CloudSyncNamespaceKey(rawValue: "private|account|background")
    let list = SnipList(id: UUID(), name: "Remote", systemImage: "folder", position: 1)
    let batch = CloudFullBatchCommit(
      namespaceKey: namespace.rawValue,
      batchID: UUID(),
      expectedEngineState: nil,
      nextEngineState: Data("next-engine-state".utf8),
      items: [CloudFullBatchItem(
        accepted: entity(.list, list.id, identity("background-list")),
        expectedLocalRevision: nil,
        expectedSystemFields: nil,
        localPrecondition: .requireMissing,
        localMutation: .upsertList(list),
        conflict: nil,
        quarantine: nil
      )]
    )
    try await store.stageCloudFullBatch(batch)
    try await SnipStoreBackgroundActivity.$runner.withValue(activity.runner) {
      do {
        _ = try await store.commitCloudFullBatch(batch)
        XCTFail("Expired store work must roll back before committing")
      } catch is CancellationError {
        // Expected: the batch stays staged and its engine state stays uncommitted.
      }
    }
    let local = try await store.checkedSnapshot(sortedBy: .manual)
    XCTAssertFalse(local.lists.contains { $0.id == list.id })
    let wire = try await store.cloudTextSyncSnapshot(namespaceKey: namespace)
    XCTAssertNil(wire.engineState)
    let staged = try await store.stagedCloudFullBatches(namespaceKey: namespace)
    XCTAssertEqual(staged.map(\.batchID), [batch.batchID])
    XCTAssertEqual(activity.ended.wait(timeout: .now() + 1), .success)

    let result = try await store.commitCloudFullBatch(batch)
    XCTAssertEqual(result, .applied)
    let replay = try await store.commitCloudFullBatch(batch)
    XCTAssertEqual(replay, .replayed)
    let final = try await store.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(final.lists.filter { $0.id == list.id }.count, 1)
    let finalWire = try await store.cloudTextSyncSnapshot(namespaceKey: namespace)
    XCTAssertEqual(finalWire.engineState, batch.nextEngineState)
  }
}


extension SnipStoreBackgroundActivityTests {
  func testExpiryKeepsTimeUntilTheOwnerReleasesTheLock() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let activity = TestStoreActivity()
    try SnipStoreBackgroundActivity.$runner.withValue(activity.runner) {
      let lock = try SnipStoreFileLock(url: url)
      defer { withExtendedLifetime(lock) {} }
      activity.expire()
      XCTAssertThrowsError(try lock.check()) { XCTAssertTrue($0 is CancellationError) }
      XCTAssertEqual(activity.ended.wait(timeout: .now()), .timedOut)
    }
    XCTAssertEqual(activity.ended.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(activity.ended.wait(timeout: .now()), .timedOut)
  }

  func testExpiryStopsAContendedLockWait() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let fd = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { flock(fd, LOCK_UN); Darwin.close(fd) }
    XCTAssertEqual(flock(fd, LOCK_EX), 0)
    let activity = TestStoreActivity()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { finished.signal() }
      SnipStoreBackgroundActivity.$runner.withValue(activity.runner) {
        do {
          _ = try SnipStoreFileLock(url: url)
          XCTFail("An expired waiter must not acquire the lock")
        } catch {
          XCTAssertTrue(error is CancellationError)
        }
      }
    }
    XCTAssertEqual(activity.started.wait(timeout: .now() + 1), .success)
    activity.expire()
    XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(activity.ended.wait(timeout: .now() + 1), .success)
  }

  func testOpenFailureEndsBackgroundTime() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathComponent("missing/lock")
    let activity = TestStoreActivity()
    try SnipStoreBackgroundActivity.$runner.withValue(activity.runner) {
      XCTAssertThrowsError(try SnipStoreFileLock(url: url))
    }
    XCTAssertEqual(activity.ended.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(activity.ended.wait(timeout: .now()), .timedOut)
  }
}

extension SnipStoreBackgroundActivityTests {
  func testFoundationWorkAndExpiryCallbacksWaitForCleanup() {
    let callback = Mutex<(@Sendable (Bool) -> Void)?>(nil)
    let expired = DispatchSemaphore(value: 0)
    let workReturned = DispatchSemaphore(value: 0)
    let expiryReturned = DispatchSemaphore(value: 0)
    let end = SnipStoreBackgroundActivity.runExpiringActivity(expire: {
      expired.signal()
    }) { body in
      callback.withLock { $0 = body }
      DispatchQueue.global().async {
        body(false)
        workReturned.signal()
      }
    }
    let body = callback.withLock { $0! }
    DispatchQueue.global().async {
      body(true)
      expiryReturned.signal()
    }
    XCTAssertEqual(expired.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(workReturned.wait(timeout: .now()), .timedOut)
    XCTAssertEqual(expiryReturned.wait(timeout: .now()), .timedOut)
    end()
    XCTAssertEqual(workReturned.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(expiryReturned.wait(timeout: .now() + 1), .success)
  }

  func testFoundationDeniedCallbackUnwindsWithoutWaitingForWork() throws {
    let callbackReturned = DispatchSemaphore(value: 0)
    let runner: SnipStoreBackgroundActivity.Runner = { expire in
      SnipStoreBackgroundActivity.runExpiringActivity(expire: expire) { body in
        DispatchQueue.global().async {
          body(true)
          callbackReturned.signal()
        }
      }
    }
    try SnipStoreBackgroundActivity.$runner.withValue(runner) {
      XCTAssertThrowsError(try SnipStoreBackgroundActivity.begin()) {
        XCTAssertTrue($0 is CancellationError)
      }
    }
    XCTAssertEqual(callbackReturned.wait(timeout: .now() + 1), .success)
  }
}

extension SnipStoreBackgroundActivityTests {
  func testActivityDeallocationEndsTime() throws {
    let activity = TestStoreActivity()
    try SnipStoreBackgroundActivity.$runner.withValue(activity.runner) {
      let scope = try SnipStoreBackgroundActivity.begin()
      withExtendedLifetime(scope) {
        XCTAssertEqual(activity.ended.wait(timeout: .now()), .timedOut)
      }
    }
    XCTAssertEqual(activity.ended.wait(timeout: .now() + 1), .success)
  }

  func testTransferMetadataReadRequiresItsOwnBackgroundTime() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    for preview in [false, true] {
      let requests = Mutex(0)
      let runner: SnipStoreBackgroundActivity.Runner = { expire in
        let count = requests.withLock { $0 += 1; return $0 }
        if count == 2 { expire() }
        return {}
      }
      try await SnipStoreBackgroundActivity.$runner.withValue(runner) {
        do {
          if preview { _ = try await library.previewTransferSnapshot(revision: 0) }
          else { _ = try await library.transferSnapshot(revision: 0) }
          XCTFail("The metadata read must not proceed after denied background time")
        } catch is CancellationError {}
      }
      XCTAssertEqual(requests.withLock { $0 }, 2)
    }
  }

  func testAttachmentExpiryStopsLaterReadsCleansUploadsAndRetries() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let urls = try (0..<3).map { index in
      let url = root.appendingPathComponent("source-\(index).txt")
      try Data("attachment \(index)".utf8).write(to: url)
      return url
    }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    _ = try await library.perform(.add(
      content: "files", origin: .quickEntry, source: nil, listID: SnipList.inbox.id,
      attachmentURLs: urls, requestID: UUID(), now: .distantPast
    ), sortedBy: .manual)
    let namespace = CloudSyncNamespaceKey(rawValue: "expiry-test")
    let reads = Mutex(0)
    let activity = TestStoreActivity()
    try await SnipStoreBackgroundActivity.$runner.withValue(activity.runner) {
      do {
        try await library.reconcileCloudAttachments(
          namespaceKey: namespace, metadataZoneName: "data", metadataOwnerName: "owner",
          payloadZoneName: "payload", payloadOwnerName: "owner",
          digestFile: { url in
            let digest = try AttachmentFileIO.digest(at: url)
            if reads.withLock({ $0 += 1; return $0 }) == 2 { activity.expire() }
            return digest
          }
        )
        XCTFail("Reconciliation must stop on expiry")
      } catch is CancellationError {}
    }
    XCTAssertEqual(reads.withLock { $0 }, 2, "Do not start reading the third attachment")
    let rolledBack = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace)
    XCTAssertTrue(rolledBack.publications.isEmpty)
    let uploadRoot = try await library.cloudAttachmentUploadRoot(namespaceKey: namespace.rawValue)
    let leftovers = FileManager.default.enumerator(at: uploadRoot, includingPropertiesForKeys: nil)?
      .allObjects as? [URL] ?? []
    XCTAssertFalse(leftovers.contains { $0.lastPathComponent == "payload" })
    try await library.reconcileCloudAttachments(
      namespaceKey: namespace, metadataZoneName: "data", metadataOwnerName: "owner",
      payloadZoneName: "payload", payloadOwnerName: "owner"
    )
    let retried = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(retried.publications.count, 3)

    // Unchanged rows do not save, but still must stop hashing on expiry.
    reads.withLock { $0 = 0 }
    let unchangedActivity = TestStoreActivity()
    try await SnipStoreBackgroundActivity.$runner.withValue(unchangedActivity.runner) {
      do {
        try await library.reconcileCloudAttachments(
          namespaceKey: namespace, metadataZoneName: "data", metadataOwnerName: "owner",
          payloadZoneName: "payload", payloadOwnerName: "owner",
          digestFile: { url in
            reads.withLock { $0 += 1 }
            let digest = try AttachmentFileIO.digest(at: url)
            unchangedActivity.expire()
            return digest
          }
        )
        XCTFail("Unchanged attachments must also stop on expiry")
      } catch is CancellationError {}
    }
    XCTAssertEqual(reads.withLock { $0 }, 1)
    let preserved = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(preserved.publications.count, 3)
  }
}

extension CloudFullRecordPersistenceTests {
  func testExpiryAfterSaveKeepsCommitAndDefersFileCleanup() async throws {
    for fullBatch in [false, true] {
      let location = temporaryStore()
      defer { try? FileManager.default.removeItem(at: location.root) }
      try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
      let source = location.root.appendingPathComponent("source.txt")
      try Data("payload".utf8).write(to: source)
      let library = try SwiftDataSnipLibrary(storeURL: location.store)
      _ = try await library.perform(.add(
        content: "file", origin: .quickEntry, source: nil, listID: SnipList.inbox.id,
        attachmentURLs: [source], requestID: UUID(), now: .distantPast
      ), sortedBy: .manual)
      let namespace = CloudSyncNamespaceKey(rawValue: "after-save")
      try await library.reconcileCloudAttachments(
        namespaceKey: namespace, metadataZoneName: "data", metadataOwnerName: "owner",
        payloadZoneName: "payload", payloadOwnerName: "owner"
      )
      let initial = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace)
      let publication = try XCTUnwrap(initial.publications.first)
      let upload = try XCTUnwrap(publication.sourceURL)
      let transitions: [CloudAttachmentTransition] = [.payloadAccepted(
        attachmentID: publication.metadata.attachmentID, expectedRevision: publication.revision,
        shadowData: Data("shadow".utf8), systemFields: Data("fields".utf8)
      )]
      let list = SnipList(id: UUID(), name: "Remote", systemImage: "folder", position: 1)
      let batch = CloudFullBatchCommit(
        namespaceKey: namespace.rawValue, batchID: UUID(), expectedEngineState: nil,
        nextEngineState: Data("committed".utf8), attachmentTransitions: transitions,
        items: [CloudFullBatchItem(
          accepted: entity(.list, list.id, identity("remote-list")),
          expectedLocalRevision: nil, expectedSystemFields: nil,
          localPrecondition: .requireMissing, localMutation: .upsertList(list),
          conflict: nil, quarantine: nil
        )]
      )
      if fullBatch { try await library.stageCloudFullBatch(batch) }
      let activity = TestStoreActivity()
      try await SnipStoreBackgroundActivity.$runner.withValue(activity.runner) {
        if fullBatch {
          let result = try await library.commitCloudFullBatch(batch, afterSave: { activity.expire() })
          XCTAssertEqual(result, .applied)
        } else {
          try await library.commitCloudAttachmentTransitions(
            namespaceKey: namespace, transitions: transitions, afterSave: { activity.expire() }
          )
        }
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: upload.path), "Defer cleanup after expiry")
      let stored = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace)
      XCTAssertTrue(try XCTUnwrap(stored.publications.first).payloadAccepted)
      if fullBatch {
        let cached = await SnipStoreBackgroundActivity.$runner.withValue({ expire in
          expire(); return {}
        }) { await library.snapshot(sortedBy: .manual) }
        XCTAssertTrue(cached.lists.contains { $0.id == list.id })
        let replay = try await library.commitCloudFullBatch(batch)
        XCTAssertEqual(replay, .replayed)
      }
      try await library.reconcileCloudAttachments(
        namespaceKey: namespace, metadataZoneName: "data", metadataOwnerName: "owner",
        payloadZoneName: "payload", payloadOwnerName: "owner"
      )
      XCTAssertFalse(FileManager.default.fileExists(atPath: upload.path), "The next sweep cleans up")
    }
  }
}
