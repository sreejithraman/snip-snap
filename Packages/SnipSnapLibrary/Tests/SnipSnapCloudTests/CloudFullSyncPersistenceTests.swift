import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
import XCTest

@testable import SnipSnapCloud

final class CloudFullSyncPersistenceTests: XCTestCase {
  func makeNamespace() -> CloudSyncNamespace {
    CloudSyncNamespace(
      cloudScope: "private",
      accountLineage: "account",
      generation: UUID(uuidString: "abababab-abab-abab-abab-abababababab")!,
      zones: [CloudZoneID(name: "SnipSnap", ownerName: "owner")]
    )
  }

  static func listNames(
    _ snapshot: SnipLibrarySnapshot,
    ids: Set<UUID>
  ) -> [SnipList] {
    snapshot.lists.filter { ids.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
  }

  static func copy(
    _ snip: Snip,
    content: String? = nil,
    source: SnipSource? = nil,
    isDone: Bool? = nil,
    listID: UUID? = nil,
    orderKey: SnipOrderKey? = nil
  ) -> Snip {
    Snip(
      id: snip.id,
      requestID: snip.requestID,
      createdAt: snip.createdAt,
      updatedAt: snip.updatedAt,
      content: content ?? snip.content,
      origin: snip.origin,
      source: source ?? snip.source,
      listID: listID ?? snip.listID,
      isDone: isDone ?? snip.isDone,
      manualSortKey: orderKey ?? snip.manualSortKey,
      attachments: snip.attachments
    )
  }
}

extension CloudFullSyncCoordinator {
  /// The app's explicit transfer, in `CloudFullRecordCollectionSyncDriver` order: fetch, then
  /// send until settled. A fetch that blocks sending ends the transfer with its own outcome.
  @discardableResult
  func fetchThenSend() async throws -> CloudFullSyncOutcome {
    let fetched = try await fetchRemote()
    if fetched.issue != nil, fetched.blocksOutbound { return fetched }
    return try await sendPendingUntilSettled()
  }

  /// Sends only the first planned batch of the app's drained send, so a test can check the
  /// state between two engine batches. Returns the outcome only when the send ended by itself
  /// after that batch; nil means a second batch was planned and stopped before it was sent.
  @discardableResult
  func sendOneBatch(
    beforeApply: @escaping @Sendable () async throws -> Void = {},
    beforeSend: @escaping @Sendable (CloudOutboundBatch) async throws -> Void = { _ in }
  ) async throws -> CloudFullSyncOutcome? {
    let stop = OneBatchStop()
    do {
      return try await sendPendingUntilSettled(beforeApply: beforeApply) { batch in
        try await stop.admit()
        try await beforeSend(batch)
      }
    } catch is OneBatchStop.Stopped {
      return nil
    }
  }

  /// `fetchThenSend()` that sends only the first planned batch.
  @discardableResult
  func fetchThenSendOneBatch() async throws -> CloudFullSyncOutcome? {
    let fetched = try await fetchRemote()
    if fetched.issue != nil, fetched.blocksOutbound { return fetched }
    return try await sendOneBatch()
  }
}

private actor OneBatchStop {
  struct Stopped: Error {}
  private var admitted = false

  func admit() throws {
    guard !admitted else { throw Stopped() }
    admitted = true
  }
}

extension SwiftDataSnipLibrary {
  /// Seeds dormant accepted bases as an earlier build's retry promotion left them.
  func testInsertDormantBases(_ bases: [CloudDormantBase]) throws {
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let context = Self.makeContext(container: container)
    for base in bases {
      context.insert(StoredCloudDormantBaseRecord(
        namespaceKey: base.namespaceKey,
        reference: base.reference,
        identity: base.identity,
        payload: base.payload
      ))
    }
    try context.save()
  }
}

actor OneShotFullApplyCrash {
  enum Failure: Error { case injected }
  private var didFail = false

  func hit() throws {
    guard !didFail else { return }
    didFail = true
    throw Failure.injected
  }
}

func XCTAssertThrowsErrorAsync(
  _ expression: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await expression()
    XCTFail("Expected an error", file: file, line: line)
  } catch {}
}
