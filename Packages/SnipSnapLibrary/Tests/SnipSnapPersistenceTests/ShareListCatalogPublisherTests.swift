import Foundation
import SnipSnapCore
import Synchronization
@testable import SnipSnapPersistence
import XCTest

@MainActor
final class ShareListCatalogPublisherTests: XCTestCase {
  func testOverlappingEnqueuesKeepTheLatestListsInTheCatalog() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let imports = ShareImportStore(sharedRootURL: root)
    let probe = ShareDestinationWriteProbe()
    let publisher = ShareListCatalogPublisher(
      imports: imports,
      beforePublish: { await probe.beforePublish() }
    )
    let work = SnipList(id: UUID(), name: "Work", systemImage: "list.bullet", position: 1)

    publisher.enqueue([.inbox])
    await probe.waitUntilFirstPublishStarted()
    publisher.enqueue([.inbox, work])
    await probe.openGate()
    await publisher.flush()

    let lists = await imports.availableLists()
    XCTAssertEqual(lists.map(\.name), ["Inbox", "Work"])
  }

  func testForcedEnqueueRepublishesListsAnotherWriterOverwrote() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let imports = ShareImportStore(sharedRootURL: root)
    let publisher = ShareListCatalogPublisher(imports: imports)
    let work = SnipList(id: UUID(), name: "Work", systemImage: "list.bullet", position: 1)

    publisher.enqueue([.inbox, work])
    await publisher.flush()
    try await imports.publishAvailableLists([.inbox])

    publisher.enqueue([.inbox, work], force: true)
    await publisher.flush()

    let lists = await imports.availableLists()
    XCTAssertEqual(lists.map(\.name), ["Inbox", "Work"])
  }

  func testFailedPublishStaysEligibleForTheNextEnqueue() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let imports = ShareImportStore(sharedRootURL: root)
    try await imports.publishAvailableLists([.inbox])
    let work = SnipList(id: UUID(), name: "Private Work", systemImage: "list.bullet", position: 1)
    let events = Mutex<[AppDiagnosticEvent]>([])
    let failure = NSError(
      domain: NSCocoaErrorDomain,
      code: NSFileWriteNoPermissionError,
      userInfo: [NSLocalizedDescriptionKey: "\(work.name) \(work.id) \(root.path)"]
    )
    let probe = FailingShareCatalogWrite(failure: failure)
    let publisher = ShareListCatalogPublisher(
      write: { lists in
        try await probe.write(lists)
        try await imports.publishAvailableLists(lists)
      },
      diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    )

    publisher.enqueue([.inbox, work])
    await publisher.flush()
    let afterFailure = await imports.availableLists()
    XCTAssertEqual(afterFailure, [.inbox])
    XCTAssertEqual(events.withLock { $0 }, [
      .failure(operation: "share.catalog_publish", errorCode: "cocoa.513", visibility: .background)
    ])
    XCTAssertEqual(events.withLock { $0.first?.operation }, "share.catalog_publish")

    publisher.enqueue([.inbox, work])
    await publisher.flush()
    publisher.enqueue([.inbox, work])
    await publisher.flush()

    let written = await probe.writtenLists()
    let attempts = await probe.attemptCount()
    let afterRetry = await imports.availableLists()
    XCTAssertEqual(written, [.inbox, work])
    XCTAssertEqual(afterRetry, [.inbox, work])
    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(events.withLock { $0.count }, 1)
    let lines = events.withLock { $0.map(\.line).joined() }
    for privateValue in [work.name, work.id.uuidString, root.path] {
      XCTAssertFalse(lines.contains(privateValue))
    }
  }

  func testFailedForceRewriteRetriesOnTheNextEnqueue() async throws {
    let probe = FailingShareCatalogWrite(failingAttempts: [2])
    let events = Mutex<[AppDiagnosticEvent]>([])
    let publisher = ShareListCatalogPublisher(
      write: { try await probe.write($0) },
      diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    )

    publisher.enqueue([.inbox])
    await publisher.flush()
    publisher.enqueue([.inbox], force: true)
    await publisher.flush()
    publisher.enqueue([.inbox])
    await publisher.flush()

    let written = await probe.writtenLists()
    let attempts = await probe.attemptCount()
    XCTAssertEqual(written, [.inbox])
    XCTAssertEqual(attempts, 3)
    XCTAssertEqual(events.withLock { $0 }, [
      .failure(
        operation: "share.catalog_publish", errorCode: "other.UnknownError", visibility: .background
      )
    ])
  }

  func testCanceledPublishStaysQuietAndRetriesOnTheNextEnqueue() async {
    let cancellations: [any Error] = [
      CancellationError(),
      NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError),
      NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
    ]
    for cancellation in cancellations {
      let events = Mutex<[AppDiagnosticEvent]>([])
      let probe = FailingShareCatalogWrite(failure: cancellation)
      let publisher = ShareListCatalogPublisher(
        write: { try await probe.write($0) },
        diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
      )

      publisher.enqueue([.inbox])
      await publisher.flush()
      publisher.enqueue([.inbox])
      await publisher.flush()

      let written = await probe.writtenLists()
      let attempts = await probe.attemptCount()
      XCTAssertEqual(written, [.inbox])
      XCTAssertEqual(attempts, 2)
      XCTAssertTrue(events.withLock { $0.isEmpty }, "\(cancellation)")
    }
  }

  func testCancellationCodesInUnrelatedDomainsStillRecordFailures() async {
    for code in [NSUserCancelledError, NSURLErrorCancelled] {
      let events = Mutex<[AppDiagnosticEvent]>([])
      let publisher = ShareListCatalogPublisher(
        write: { _ in throw NSError(domain: "private.error.domain", code: code) },
        diagnostics: AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
      )

      publisher.enqueue([.inbox])
      await publisher.flush()

      XCTAssertEqual(events.withLock { $0 }, [
        .failure(
          operation: "share.catalog_publish", errorCode: "other.UnknownError", visibility: .background
        )
      ])
      XCTAssertFalse(events.withLock { $0.map(\.line).joined().contains("private.error.domain") })
    }
  }

  func testStoreBackedPublisherRecordsWriteFailureThenRetriesAfterRepair() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let catalog = root.appendingPathComponent("Share/destinations.json")
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
    let events = Mutex<[AppDiagnosticEvent]>([])
    let recorder = AppDiagnosticRecorder { event in events.withLock { $0.append(event) } }
    let imports = ShareImportStore(sharedRootURL: root, diagnostics: recorder)
    let publisher = ShareListCatalogPublisher(imports: imports, diagnostics: recorder)

    publisher.enqueue([.inbox])
    await publisher.flush()

    let failure = try XCTUnwrap(events.withLock { $0.first })
    XCTAssertEqual(events.withLock { $0.count }, 1)
    XCTAssertEqual(failure.operation, "share.catalog_publish")
    XCTAssertEqual(failure.outcome, .failed)
    XCTAssertEqual(failure.visibility, .background)
    XCTAssertTrue(try XCTUnwrap(failure.errorCode).hasPrefix("cocoa."))
    XCTAssertFalse(failure.line.contains(root.path))
    try FileManager.default.removeItem(at: catalog)

    publisher.enqueue([.inbox])
    await publisher.flush()

    let lists = await imports.availableLists()
    XCTAssertEqual(lists, [.inbox])
    XCTAssertEqual(events.withLock { $0.count }, 1)
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "ShareListCatalogPublisherTests-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

/// Holds the first publish at a gate so a second enqueue must overtake it unless
/// the publisher serializes its writes.
private actor ShareDestinationWriteProbe {
  private var firstPublishStarted = false
  private var gateIsOpen = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var gateWaiters: [CheckedContinuation<Void, Never>] = []

  func beforePublish() async {
    guard !firstPublishStarted else { return }
    firstPublishStarted = true
    startWaiters.forEach { $0.resume() }
    startWaiters.removeAll()
    guard !gateIsOpen else { return }
    await withCheckedContinuation { gateWaiters.append($0) }
  }

  func waitUntilFirstPublishStarted() async {
    guard !firstPublishStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func openGate() {
    gateIsOpen = true
    gateWaiters.forEach { $0.resume() }
    gateWaiters.removeAll()
  }
}

private actor FailingShareCatalogWrite {
  private var attempts = 0
  private var written: [SnipList] = []
  private let failingAttempts: Set<Int>
  private let failure: any Error

  init(
    failingAttempts: Set<Int> = [1],
    failure: any Error = ShareImportError.invalidStaging
  ) {
    self.failingAttempts = failingAttempts
    self.failure = failure
  }

  func write(_ lists: [SnipList]) throws {
    attempts += 1
    if failingAttempts.contains(attempts) { throw failure }
    written = lists
  }

  func writtenLists() -> [SnipList] { written }
  func attemptCount() -> Int { attempts }
}

extension ShareListCatalogPublisherTests {
  func testRetiredCheckedRootCannotWriteItsDelayedCatalog() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CheckedCatalog-\(UUID())")
    NSLog("CheckedCatalog retained store root: %@", root.path)
    let persistence = try SwiftDataSyncModePersistence(rootURL: root.appendingPathComponent("Mode"))
    try await persistence.activateEmptyCollection(namespace: ICloudSyncNamespaceBinding(
      scope: "private", accountLineage: "catalog-original",
      generation: UUID(uuidString: "AAAAAAAA-1111-2222-3333-AAAAAAAAAAAA")!,
      zones: [ICloudSyncZoneBinding(name: "catalog-original", ownerName: "owner")]))
    let library = try await persistence.activeLibrary()
    let work = SnipList(id: UUID(uuidString: "11111111-AAAA-BBBB-CCCC-111111111111")!,
      name: "Retired Work", systemImage: "folder", position: 1)
    _ = try await library.perform(.restoreList(work), sortedBy: .manual)
    let session = SavedSnipsSession(library: library)
    let read = try await session.checkedRead(sortedBy: .manual)
    XCTAssertEqual(read.snapshot.lists.map(\.name).sorted(), ["Inbox", "Retired Work"])
    let publication = try XCTUnwrap(read.publication)
    let imports = ShareImportStore(sharedRootURL: root.appendingPathComponent("Share"))
    try await imports.publishAvailableLists([.inbox])
    let catalog = ShareImportPaths(rootURL: root.appendingPathComponent("Share")).catalogURL
    let originalBytes = try Data(contentsOf: catalog)
    let pause = CheckedCatalogPause()
    let publisher = ShareListCatalogPublisher(imports: imports, beforePublish: { await pause.wait() })
    let finished = XCTestExpectation(description: "checked catalog publication joined")
    publisher.enqueue(read.snapshot.lists, publication: publication)
    let flush = Task {
      defer { finished.fulfill() }
      await publisher.flush()
    }
    var failure: (any Error)?
    do {
      let entered = await XCTWaiter.fulfillment(of: [pause.entered], timeout: 30)
      XCTAssertEqual(entered, .completed)
      if entered == .completed {
        try await persistence.activateEmptyCollection(namespace: nil)
        let replacement = try await session.checkedRead(sortedBy: .manual)
        XCTAssertNotEqual(replacement.source?.storeID, read.source?.storeID)
        XCTAssertEqual(replacement.snapshot.lists.map(\.name), ["Inbox"])
        let whileHeld = await imports.availableLists()
        XCTAssertEqual(whileHeld, [.inbox])
      }
    } catch { failure = error }
    pause.release()
    let joined = await XCTWaiter.fulfillment(of: [finished], timeout: 30)
    XCTAssertEqual(joined, .completed, "Cleanup must join the publisher before releasing its ownership")
    if joined == .completed {
      await flush.value
      let after = await imports.availableLists()
      XCTAssertEqual(after, [.inbox], "A retired root cannot reach the actual catalog write")
      XCTAssertEqual(try Data(contentsOf: catalog), originalBytes,
        "A corrupt or missing catalog must not masquerade as the Inbox fallback")
      _ = try await library.perform(.restoreList(work), sortedBy: .manual)
      let current = try await session.checkedRead(sortedBy: .manual)
      XCTAssertEqual(current.snapshot.lists, [.inbox, work])
      // The existing enqueue must still write this now-valid payload; rejection cannot cache a success.
      publisher.enqueue([.inbox, work])
      let laterFinished = XCTestExpectation(description: "current catalog publication joined")
      let later = Task { await publisher.flush(); laterFinished.fulfill() }
      let laterJoined = await XCTWaiter.fulfillment(of: [laterFinished], timeout: 30)
      XCTAssertEqual(laterJoined, .completed)
      if laterJoined == .completed {
        await later.value
        let afterCurrent = await imports.availableLists()
        XCTAssertEqual(afterCurrent, [.inbox, work])
      } else {
        later.cancel()
        NSLog("CheckedCatalog retained current publisher/root after failed join: %@", root.path)
      }
    } else {
      flush.cancel()
      NSLog("CheckedCatalog retained live publisher and root after failed join: %@", root.path)
    }
    if let failure { throw failure }
  }
}

private final class CheckedCatalogPause: @unchecked Sendable {
  let entered = XCTestExpectation(description: "checked catalog preparation entered")
  private let lock = NSLock()
  private var released = false
  private var signalled = false
  private var waiter: CheckedContinuation<Void, Never>?

  func wait() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let observation = lock.withLock {
          let first = !signalled
          signalled = true
          if released { return (finish: true, first: first) }
          waiter = continuation
          return (finish: false, first: first)
        }
        if observation.first { entered.fulfill() }
        if observation.finish { continuation.resume() }
      }
    } onCancel: { self.release() }
  }

  func release() {
    let continuation = lock.withLock {
      released = true
      defer { waiter = nil }
      return waiter
    }
    continuation?.resume()
  }
}


extension ShareListCatalogPublisherTests {
  func testManagedLocalListChangeCanPublishAfterItsMutationRevokesTheEarlierRead() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCheckedCatalog-\(UUID())")
    NSLog("LocalCheckedCatalog retained store root: %@", root.path)
    let persistence = try SwiftDataSyncModePersistence(rootURL: root.appendingPathComponent("Mode"))
    let library = try await persistence.activeLibrary()
    let session = SavedSnipsSession(library: library)
    let initial = try await session.checkedRead(sortedBy: .manual)
    let target = try XCTUnwrap(initial.target)
    let imports = ShareImportStore(sharedRootURL: root.appendingPathComponent("Share"))
    try await imports.publishAvailableLists([.inbox])
    let work = SnipList(id: UUID(uuidString: "33333333-AAAA-BBBB-CCCC-333333333333")!,
      name: "Local offline Work", systemImage: "briefcase", position: 1)
    let update = try await session.performUserCommand(.restoreList(work), sortedBy: .manual)
    do {
      let closing = try XCTUnwrap(initial.publication).beginApplication()
      closing.finish()
      XCTFail("The real local mutation must retire the earlier read, even though the source remains the same")
    } catch { XCTAssertTrue(error is SnipLibraryReadPublicationError) }
    let publisher = ShareListCatalogPublisher(imports: imports)
    publisher.enqueue(update.snapshot.lists, from: session, target: target)
    let finished = XCTestExpectation(description: "source-bound local catalog preparation and write joined")
    let flush = Task { await publisher.flush(); finished.fulfill() }
    let joined = await XCTWaiter.fulfillment(of: [finished], timeout: 30) == .completed
    XCTAssertTrue(joined)
    if joined {
      await flush.value
      let actual = await imports.availableLists()
      XCTAssertEqual(actual, [.inbox, work])
      let reopened = try SwiftDataSyncModePersistence(rootURL: root.appendingPathComponent("Mode"))
      let durable = try await (try await reopened.activeLibrary()).checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(durable.lists, [.inbox, work])
      XCTAssertEqual(durable.snips, [])
    } else {
      flush.cancel()
      NSLog("LocalCheckedCatalog retained live publisher and root after failed join: %@", root.path)
    }
  }
}
