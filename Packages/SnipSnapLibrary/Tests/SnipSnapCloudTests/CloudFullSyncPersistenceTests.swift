import Foundation
import SnipSnapCore
import SnipSnapPersistence
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
