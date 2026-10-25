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
