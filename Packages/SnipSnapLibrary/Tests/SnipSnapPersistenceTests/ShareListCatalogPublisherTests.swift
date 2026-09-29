import Foundation
import SnipSnapCore
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
    let probe = FailingShareCatalogWrite()
    let publisher = ShareListCatalogPublisher(write: { lists in
      try await probe.write(lists)
    })

    publisher.enqueue([.inbox])
    await publisher.flush()
    publisher.enqueue([.inbox])
    await publisher.flush()

    let written = await probe.writtenLists()
    let attempts = await probe.attemptCount()
    XCTAssertEqual(written, [.inbox])
    XCTAssertEqual(attempts, 2)
  }

  func testFailedForceRewriteRetriesOnTheNextEnqueue() async throws {
    let probe = FailingShareCatalogWrite(failingAttempts: [2])
    let publisher = ShareListCatalogPublisher(write: { lists in
      try await probe.write(lists)
    })

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

  init(failingAttempts: Set<Int> = [1]) {
    self.failingAttempts = failingAttempts
  }

  func write(_ lists: [SnipList]) throws {
    attempts += 1
    if failingAttempts.contains(attempts) { throw ShareImportError.invalidStaging }
    written = lists
  }

  func writtenLists() -> [SnipList] { written }
  func attemptCount() -> Int { attempts }
}
