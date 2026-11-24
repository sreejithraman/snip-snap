import Foundation
import SwiftData
import XCTest

@testable import SnipSnapCore
@testable import SnipSnapPersistence

/// Literal stored forms written by builds before the enrollment machines. Old and new
/// builds must keep reading and writing each other's rows.
final class CloudEnrollmentStorageFormatTests: XCTestCase {
  private let namespace = CloudSyncNamespaceKey(rawValue: "private|account-a|generation-format")
  private static let listID = "8D5F2C1E-3B7A-4E9C-9A61-0F2B7C4D5E6A"
  private static let reference = #"{"kind":"list","domainID":"\#(CloudEnrollmentStorageFormatTests.listID)"}"#
  private static let freshInventory = #"{"observed":[],"canProveAbsence":true}"#
  private static let observedInventory =
    #"{"observed":[{"zoneName":"SnipSnap","ownerName":"owner","recordName":"list-record"}],"#
      + #""canProveAbsence":false}"#

  private struct NamespaceFixture {
    let phase: CloudNamespaceBootstrapPhase
    let revision: UInt64
    let zoneCreationPending: Bool
    let inventory: String?

    var label: String {
      "\(phase.rawValue) rev \(revision) pending \(zoneCreationPending) inventory \(inventory ?? "none")"
    }

    func json(revision: UInt64? = nil, inventory: String? = nil) -> String {
      let inventoryField = (inventory ?? self.inventory).map { #","initialFetchInventory":\#($0)"# } ?? ""
      return #"{"storageVersion":1,"revision":\#(revision ?? self.revision),"#
        + #""phase":"\#(phase.rawValue)","zoneCreationPending":\#(zoneCreationPending)\#(inventoryField)}"#
    }
  }

  // Active with pending zone creation is SM27-L1 and heals on read; see CloudFullSyncEnrollmentTests.
  private static let namespaceFixtures: [NamespaceFixture] = [
    NamespaceFixture(phase: .notEnrolled, revision: 0, zoneCreationPending: false, inventory: nil),
    NamespaceFixture(phase: .notEnrolled, revision: 1, zoneCreationPending: false,
      inventory: CloudEnrollmentStorageFormatTests.freshInventory),
    NamespaceFixture(phase: .remoteChecked, revision: 2, zoneCreationPending: false, inventory: nil),
    NamespaceFixture(phase: .remoteChecked, revision: 3, zoneCreationPending: true,
      inventory: CloudEnrollmentStorageFormatTests.observedInventory),
    NamespaceFixture(phase: .remoteCheckedMissingZone, revision: 4, zoneCreationPending: false, inventory: nil),
    NamespaceFixture(phase: .remoteCheckedMissingZone, revision: 5, zoneCreationPending: true, inventory: nil),
    NamespaceFixture(phase: .remoteCheckedMissingZone, revision: 5, zoneCreationPending: true,
      inventory: CloudEnrollmentStorageFormatTests.observedInventory),
    NamespaceFixture(phase: .seeding, revision: 6, zoneCreationPending: false, inventory: nil),
    NamespaceFixture(phase: .seeding, revision: 7, zoneCreationPending: true, inventory: nil),
    NamespaceFixture(phase: .seeding, revision: 7, zoneCreationPending: true,
      inventory: CloudEnrollmentStorageFormatTests.freshInventory),
    NamespaceFixture(phase: .active, revision: 8, zoneCreationPending: false, inventory: nil),
    NamespaceFixture(phase: .active, revision: 9, zoneCreationPending: false,
      inventory: CloudEnrollmentStorageFormatTests.observedInventory),
    NamespaceFixture(phase: .blocked, revision: 10, zoneCreationPending: false, inventory: nil),
    NamespaceFixture(phase: .blocked, revision: 11, zoneCreationPending: true,
      inventory: CloudEnrollmentStorageFormatTests.freshInventory),
  ]

  private static func envelope(
    _ namespaceState: String,
    references: String = CloudEnrollmentStorageFormatTests.reference
  ) -> String {
    #"{"storageVersion":1,"namespaceState":\#(namespaceState),"references":[\#(references)]}"#
  }

  func testFullEnrollmentFixturesDecodeAndReencodeUnchanged() throws {
    for fixture in Self.namespaceFixtures {
      let data = Data(Self.envelope(fixture.json()).utf8)
      let decoded = try SwiftDataSnipLibrary.fullEnrollmentState(from: data)
      try assertNamespace(decoded.namespaceState, matches: fixture, fixture.label)
      XCTAssertEqual(decoded.references, [CloudEntityReference(kind: .list, domainID: try Self.listUUID())],
        fixture.label)
      XCTAssertEqual(try Self.canonical(JSONEncoder().encode(decoded)), try Self.canonical(data), fixture.label)
    }
  }

  func testStoredFullEnrollmentRowsKeepTheirFormatWhenAFreshAttemptStarts() async throws {
    for fixture in Self.namespaceFixtures {
      let location = temporaryStore()
      defer { try? FileManager.default.removeItem(at: location.root) }
      let store = try SwiftDataSnipLibrary(storeURL: location.store)
      try await store.insertEnrollmentRow(namespaceKey: namespace.rawValue,
        data: Data(Self.envelope(fixture.json()).utf8))

      let snapshot = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
      try assertNamespace(snapshot.namespaceState, matches: fixture, fixture.label)
      XCTAssertEqual(snapshot.enrolledEntities,
        [CloudEntityReference(kind: .list, domainID: try Self.listUUID())], fixture.label)

      try await store.clearCloudEngineState(namespaceKey: namespace, resetsFullRecordInitialFetch: true)
      let written = try await store.enrollmentRowData(namespaceKey: namespace.rawValue)
      let expected = Self.envelope(fixture.json(revision: fixture.revision + 1, inventory: Self.freshInventory))
      XCTAssertEqual(try Self.canonical(try XCTUnwrap(written)), try Self.canonical(Data(expected.utf8)),
        fixture.label)
    }
  }

  func testLegacyReferenceArraysDecodeAsRevisionZeroAndUpgradeOnWrite() async throws {
    let cases: [(String, String, CloudNamespaceBootstrapPhase)] = [
      ("[]", "", .notEnrolled),
      ("[\(Self.reference)]", Self.reference, .active),
    ]
    for (legacy, references, phase) in cases {
      let decoded = try SwiftDataSnipLibrary.fullEnrollmentState(from: Data(legacy.utf8))
      XCTAssertEqual(decoded.namespaceState.phase, phase, legacy)
      XCTAssertEqual(decoded.namespaceState.revision, 0, legacy)
      XCTAssertFalse(decoded.namespaceState.zoneCreationPending, legacy)
      XCTAssertNil(decoded.namespaceState.initialFetchInventory, legacy)
      XCTAssertEqual(decoded.namespaceState.storageVersion, 1, legacy)

      let location = temporaryStore()
      defer { try? FileManager.default.removeItem(at: location.root) }
      let store = try SwiftDataSnipLibrary(storeURL: location.store)
      try await store.insertEnrollmentRow(namespaceKey: namespace.rawValue, data: Data(legacy.utf8))
      try await store.clearCloudEngineState(namespaceKey: namespace, resetsFullRecordInitialFetch: true)
      let written = try await store.enrollmentRowData(namespaceKey: namespace.rawValue)
      let upgraded = NamespaceFixture(phase: phase, revision: 1, zoneCreationPending: false,
        inventory: Self.freshInventory)
      XCTAssertEqual(try Self.canonical(try XCTUnwrap(written)),
        try Self.canonical(Data(Self.envelope(upgraded.json(), references: references).utf8)), legacy)
    }
    let missing = try SwiftDataSnipLibrary.fullEnrollmentState(from: nil)
    XCTAssertEqual(missing.namespaceState.phase, .notEnrolled)
    XCTAssertEqual(missing.namespaceState.revision, 0)
    XCTAssertTrue(missing.references.isEmpty)
  }

  /// Every tagged build since v0.6.0-beta.118 writes `hasPlannedDeferredReleases`. A staged plan
  /// without it is refused: it cannot be read or applied, library writes fail, and the row stays.
  func testStagedPlanWithoutDeferredReleaseFlagIsRefusedAndKept() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let batchID = UUID()
    let fields = #""attachmentTransitions":[],"batchID":"\#(batchID.uuidString)","items":[],"#
      + #""namespaceKey":"\#(namespace.rawValue)","outboundBindings":[],"recoveryInputs":[],"#
      + #""recoveryReviews":[],"settledDeleteIdentities":[],"storageVersion":1"#
    XCTAssertNoThrow(try JSONDecoder().decode(CloudFullBatchCommit.self,
      from: Data(#"{"hasPlannedDeferredReleases":true,\#(fields)}"#.utf8)))
    let legacy = Data("{\(fields)}".utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(CloudFullBatchCommit.self, from: legacy))
    let payload = try CloudWirePayloadEnvelope(format: .fullRecordV1, payload: legacy).encoded()
    try await store.insertStagedRow(namespaceKey: namespace.rawValue, batchID: batchID, payload: payload)

    do {
      _ = try await store.stagedCloudFullBatches(namespaceKey: namespace)
      XCTFail("A staged plan without hasPlannedDeferredReleases must be unreadable.")
    } catch {}
    do {
      _ = try await store.perform(
        .add(content: "blocked", origin: .quickEntry, source: nil, listID: SnipList.inboxID,
          attachmentURLs: [], requestID: UUID(), now: Date()),
        sortedBy: .manual)
      XCTFail("Writes must stay refused while an unreadable staged plan remains.")
    } catch {}

    let kept = try await store.stagedRowPayloads()
    XCTAssertEqual(kept, [payload])
  }

  func testUnknownEnrollmentStorageVersionsAreInvalid() throws {
    let fixture = NamespaceFixture(phase: .seeding, revision: 2, zoneCreationPending: true, inventory: nil)
    let unknownEnvelope = Self.envelope(fixture.json()).replacingOccurrences(
      of: #"{"storageVersion":1,"namespaceState""#, with: #"{"storageVersion":2,"namespaceState""#)
    let unknownState = Self.envelope(fixture.json().replacingOccurrences(
      of: #"{"storageVersion":1,"#, with: #"{"storageVersion":2,"#))
    for value in [unknownEnvelope, unknownState] {
      XCTAssertThrowsError(try SwiftDataSnipLibrary.fullEnrollmentState(from: Data(value.utf8))) { error in
        XCTAssertEqual(error as? SnipLibraryError, .invalidStore, value)
      }
    }
  }

  func testStagedNamespaceStateRoundTripsInsideABatchCommit() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for fixture in Self.namespaceFixtures {
      let commit = Self.commitJSON(expectedRevision: fixture.revision,
        nextState: fixture.json(revision: fixture.revision + 1))
      let decoded = try JSONDecoder().decode(CloudFullBatchCommit.self, from: Data(commit.utf8))
      XCTAssertEqual(decoded.expectedNamespaceRevision, fixture.revision, fixture.label)
      let next = try XCTUnwrap(decoded.nextNamespaceState, fixture.label)
      XCTAssertEqual(next.phase, fixture.phase, fixture.label)
      XCTAssertEqual(next.revision, fixture.revision + 1, fixture.label)
      XCTAssertEqual(next.zoneCreationPending, fixture.zoneCreationPending, fixture.label)
      XCTAssertEqual(try Self.canonical(encoder.encode(decoded)), try Self.canonical(Data(commit.utf8)),
        fixture.label)
    }
  }

  func testNamespaceCommitsRequireTheStoredRevisionAndAdvanceItByOne() async throws {
    let location = temporaryStore()
    defer { try? FileManager.default.removeItem(at: location.root) }
    let store = try SwiftDataSnipLibrary(storeURL: location.store)
    let checked = NamespaceFixture(phase: .remoteChecked, revision: 1, zoneCreationPending: false, inventory: nil)
    let active = NamespaceFixture(phase: .active, revision: 1, zoneCreationPending: false, inventory: nil)

    let first = try Self.commit(expectedRevision: 0, nextState: checked.json())
    try await store.stageCloudFullBatch(first)
    _ = try await store.commitCloudFullBatch(first)
    var snapshot = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(snapshot.namespaceState.phase, .remoteChecked)
    XCTAssertEqual(snapshot.namespaceState.revision, 1)

    let rejected = [
      try Self.commit(expectedRevision: 0, nextState: active.json()),
      try Self.commit(expectedRevision: 1, nextState: active.json(revision: 3)),
      try Self.commit(expectedRevision: 1, nextState: active.json(revision: 1)),
    ]
    for batch in rejected {
      try await store.stageCloudFullBatch(batch)
      do {
        _ = try await store.commitCloudFullBatch(batch)
        XCTFail("Expected a namespace revision mismatch.")
      } catch {
        XCTAssertEqual(error as? CloudFullStorageError, .namespaceStateMismatch)
      }
    }
    snapshot = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(snapshot.namespaceState.phase, .remoteChecked)
    XCTAssertEqual(snapshot.namespaceState.revision, 1)

    let next = try Self.commit(expectedRevision: 1, nextState: active.json(revision: 2))
    try await store.stageCloudFullBatch(next)
    _ = try await store.commitCloudFullBatch(next)
    snapshot = try await store.cloudFullStorageSnapshot(namespaceKey: namespace)
    XCTAssertEqual(snapshot.namespaceState.phase, .active)
    XCTAssertEqual(snapshot.namespaceState.revision, 2)
  }

  private func assertNamespace(
    _ state: CloudFullNamespaceState,
    matches fixture: NamespaceFixture,
    _ label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    XCTAssertEqual(state.storageVersion, 1, label, file: file, line: line)
    XCTAssertEqual(state.revision, fixture.revision, label, file: file, line: line)
    XCTAssertEqual(state.phase, fixture.phase, label, file: file, line: line)
    XCTAssertEqual(state.zoneCreationPending, fixture.zoneCreationPending, label, file: file, line: line)
    guard let inventory = fixture.inventory else {
      XCTAssertNil(state.initialFetchInventory, label, file: file, line: line)
      return
    }
    let observed: Set<CloudTextStorageIdentity> = inventory == Self.freshInventory ? [] : [
      CloudTextStorageIdentity(zoneName: "SnipSnap", ownerName: "owner", recordName: "list-record"),
    ]
    XCTAssertEqual(state.initialFetchInventory?.observed, observed, label, file: file, line: line)
    XCTAssertEqual(state.initialFetchInventory?.canProveAbsence, inventory == Self.freshInventory, label,
      file: file, line: line)
  }

  private static func commitJSON(
    batchID: UUID = UUID(uuidString: "6B1C2D3E-4F50-4617-8293-A4B5C6D7E8F0")!,
    expectedRevision: UInt64,
    nextState: String
  ) -> String {
    #"{"attachmentTransitions":[],"batchID":"\#(batchID.uuidString)","#
      + #""expectedNamespaceRevision":\#(expectedRevision),"hasPlannedDeferredReleases":true,"items":[],"#
      + #""namespaceKey":"private|account-a|generation-format","nextNamespaceState":\#(nextState),"#
      + #""outboundBindings":[],"recoveryInputs":[],"recoveryReviews":[],"settledDeleteIdentities":[],"#
      + #""storageVersion":1}"#
  }

  private static func commit(expectedRevision: UInt64, nextState: String) throws -> CloudFullBatchCommit {
    let json = commitJSON(batchID: UUID(), expectedRevision: expectedRevision, nextState: nextState)
    return try JSONDecoder().decode(CloudFullBatchCommit.self, from: Data(json.utf8))
  }

  private func temporaryStore() -> (root: URL, store: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudEnrollmentStorageFormatTests-\(UUID().uuidString)")
    return (root, root.appendingPathComponent("snips.store"))
  }

  private static func listUUID() throws -> UUID {
    try XCTUnwrap(UUID(uuidString: CloudEnrollmentStorageFormatTests.listID))
  }

  private static func canonical(_ data: Data) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data)
    let sorted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: sorted, as: UTF8.self)
  }
}

private extension SwiftDataSnipLibrary {
  func insertEnrollmentRow(namespaceKey: String, data: Data) throws {
    let context = Self.makeContext(container: try XCTUnwrap(container))
    context.insert(StoredCloudFullEnrollment(namespaceKey: namespaceKey, referencesData: data))
    try context.save()
  }

  func insertStagedRow(namespaceKey: String, batchID: UUID, payload: Data) throws {
    let context = Self.makeContext(container: try XCTUnwrap(container))
    context.insert(StoredCloudStagedBatch(namespaceKey: namespaceKey, batchID: batchID, payload: payload))
    try context.save()
  }

  func stagedRowPayloads() throws -> [Data] {
    let context = Self.makeContext(container: try XCTUnwrap(container))
    return try context.fetch(FetchDescriptor<StoredCloudStagedBatch>()).map(\.payload)
  }

  func enrollmentRowData(namespaceKey: String) throws -> Data? {
    let context = Self.makeContext(container: try XCTUnwrap(container))
    return try context.fetch(FetchDescriptor<StoredCloudFullEnrollment>())
      .first { $0.namespaceKey == namespaceKey }?.referencesData
  }
}
