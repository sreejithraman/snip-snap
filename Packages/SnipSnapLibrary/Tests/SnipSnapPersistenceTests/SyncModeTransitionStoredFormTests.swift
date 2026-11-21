import Foundation
import SnipSnapCore
import XCTest
@testable import SnipSnapPersistence

/// Pins the stored `transition` object in `activation.json`. Older and newer builds read each
/// other's manifests, so these tests compare stored JSON, not the Swift type's fields.
final class SyncModeTransitionStoredFormTests: XCTestCase {
  // MARK: Golden round trip

  func testEveryStoredTransitionShapeRoundTripsUnchanged() throws {
    for (shape, stored) in Self.storedShapes {
      let decoded = try JSONDecoder().decode(SyncModeTransition.self, from: Data(stored.utf8))
      XCTAssertEqual(
        try Self.canonical(Self.encoded(decoded)),
        try Self.canonical(Data(stored.utf8)),
        shape
      )
    }
  }

  func testLegacySnipIDOperationReencodesAsASnipReference() throws {
    let stored = Self.transition(
      "firstSendStarted",
      freezeToken: Self.storedToken,
      freezeSnapshotTaken: true,
      approvedSnipIDs: Self.approvedSnipIDs,
      sendAttempt: Self.sendAttemptJSON(snipAKey: Self.legacySnipAKey),
      pendingSettlementSnipIDs: Self.recordedSendSnipIDs
    )
    let reencoded = Self.transition(
      "firstSendStarted",
      freezeToken: Self.storedToken,
      freezeSnapshotTaken: true,
      approvedSnipIDs: Self.approvedSnipIDs,
      sendAttempt: Self.sendAttemptJSON(snipAKey: Self.snipAReferenceKey),
      pendingSettlementSnipIDs: Self.recordedSendSnipIDs
    )

    let decoded = try JSONDecoder().decode(SyncModeTransition.self, from: Data(stored.utf8))

    XCTAssertEqual(
      try Self.canonical(Self.encoded(decoded)),
      try Self.canonical(Data(reencoded.utf8))
    )
  }

  func testTransitionWithoutNamespaceOrProtocolReencodesLegacyText() throws {
    let stored = """
      {
        "approvedSnipIDs": [],
        "candidateStoreID": "\(ID.candidateStore)",
        "captureAcceptedServerProvenance": false,
        "freezeSnapshotTaken": false,
        "id": "\(ID.transition)",
        "pendingSettlementSnipIDs": [],
        "phase": "candidateReady",
        "seedProvenance": [],
        "seededListIDs": [],
        "serverAcceptedSeedSnipIDs": [],
        "sourceStoreID": "\(ID.sourceStore)",
        "supersededApprovedSnipIDs": [],
        "targetKind": "localOnly"
      }
      """
    let reencoded = """
      {
        "approvedSnipIDs": [],
        "candidateStoreID": "\(ID.candidateStore)",
        "captureAcceptedServerProvenance": false,
        "freezeSnapshotTaken": false,
        "id": "\(ID.transition)",
        "pendingSettlementSnipIDs": [],
        "phase": "candidateReady",
        "seedProvenance": [],
        "seededListIDs": [],
        "serverAcceptedSeedSnipIDs": [],
        "sourceStoreID": "\(ID.sourceStore)",
        "supersededApprovedSnipIDs": [],
        "syncProtocol": "legacyTextV1",
        "targetKind": "localOnly"
      }
      """

    let decoded = try JSONDecoder().decode(SyncModeTransition.self, from: Data(stored.utf8))

    XCTAssertNil(decoded.namespace)
    XCTAssertEqual(decoded.syncProtocol, .retiredText)
    XCTAssertEqual(
      try Self.canonical(Self.encoded(decoded)),
      try Self.canonical(Data(reencoded.utf8))
    )
  }

  // MARK: Derived reads

  func testOnlyStagesFromTheFreezeToThePointerSwapFreezeTheSource() throws {
    let freezesSource: [SyncModeTransitionPhase: Bool] = [
      .candidateDeclared: false,
      .candidateReady: false,
      .remoteFetched: false,
      .sourceFrozen: true,
      .recordsMerged: true,
      .enrollmentApproved: true,
      .firstSendStarted: true,
      .firstSendComplete: true,
      .pointerSwapped: false,
    ]
    var checkedPhases: Set<SyncModeTransitionPhase> = []
    for (shape, stored) in Self.storedShapes {
      let decoded = try JSONDecoder().decode(SyncModeTransition.self, from: Data(stored.utf8))
      XCTAssertEqual(decoded.freezesSource, freezesSource[decoded.phase], shape)
      checkedPhases.insert(decoded.phase)
    }
    XCTAssertEqual(checkedPhases, Set(freezesSource.keys))
  }

  // MARK: Writer deltas

  func testEnableWritersChangeOnlyTheirStoredFields() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = StoredManifestProbe(root: root)
    let persistence = try SwiftDataSyncModePersistence(
      rootURL: root,
      defaultSyncProtocol: .fullRecordV1,
      crashHook: probe.hit
    )
    let snip = try await addSnip("seed", to: persistence)
    let sourceStoreID = try await persistence.snapshot().activeStore.id

    let begun = try await persistence.beginTransition(to: .iCloudSync, namespace: Self.binding)
    let declared = try XCTUnwrap(probe.transition(at: .afterCandidateManifest))
    let expectedDeclared = Self.declaredTransition(
      begun,
      sourceStoreID: sourceStoreID,
      targetFields: Self.enableTargetFields
    )
    XCTAssertEqual(
      try Self.canonicalText(declared),
      try Self.canonical(Data(expectedDeclared.utf8))
    )
    var trail = StoredTransitionTrail(root: root, last: declared)
    try trail.expect(["phase": "candidateReady"], after: "begin")

    try await persistence.recordPreparationComplete()
    try trail.expect(["phase": "remoteFetched"], after: "preparation complete")
    try await persistence.retryRemoteFetch()
    try trail.expect(["phase": "candidateReady"], after: "retry fetch")
    try await persistence.recordPreparationComplete()
    try trail.expect(["phase": "remoteFetched"], after: "second preparation complete")

    let firstToken = try await persistence.freezeSource()
    let firstTokenForm = try Self.storedForm(firstToken)
    try trail.expect(["phase": "sourceFrozen", "freezeToken": firstTokenForm], after: "freeze")
    _ = try await persistence.finalSnapshot(using: firstToken)
    try trail.expect(["freezeSnapshotTaken": true], after: "final snapshot")
    try await persistence.unfreezeBeforePointerSwap()
    try trail.expect(
      [
        "phase": "remoteFetched",
        "freezeToken": nil,
        "freezeSnapshotTaken": false,
        "approvedSnipIDs": [String](),
      ],
      after: "unfreeze without a merge intent"
    )

    let token = try await persistence.freezeSource()
    let tokenForm = try Self.storedForm(token)
    try trail.expect(["phase": "sourceFrozen", "freezeToken": tokenForm], after: "second freeze")
    let source = try await persistence.finalSnapshot(using: token)
    try trail.expect(["freezeSnapshotTaken": true], after: "second final snapshot")

    _ = try await persistence.mergeFinalSnapshot(source, using: token)
    let intended = try XCTUnwrap(probe.transition(at: .beforeCandidateMergeDurability))
    let intent = try XCTUnwrap(intended["mergeIntent"] as? [String: Any])
    XCTAssertEqual(intent["approvedSnipIDs"] as? [String], [snip.id.uuidString])
    XCTAssertEqual(intent["recoveredSourceSnipIDs"] as? [String], [])
    XCTAssertEqual(intent["sourceRevision"] as? Int, Int(token.revision))
    XCTAssertNil(intent["fullReenablePlanID"])
    let provenance = try XCTUnwrap(intent["seedProvenance"] as? [[String: Any]])
    XCTAssertEqual(provenance.count, 1)
    XCTAssertEqual(provenance.first?["sourceSnipID"] as? String, snip.id.uuidString)
    XCTAssertEqual(provenance.first?["candidateSnipID"] as? String, snip.id.uuidString)
    XCTAssertEqual(provenance.first?["candidateRequestID"] as? String, snip.requestID.uuidString)
    try trail.expect(intended, ["mergeIntent": intent], after: "merge intent")
    try trail.expect(
      [
        "phase": "recordsMerged",
        "approvedSnipIDs": intent["approvedSnipIDs"],
        "seedProvenance": intent["seedProvenance"],
        "seededListIDs": intent["seededListIDs"],
        "pendingSettlementSnipIDs": [String](),
        "sendAttempt": nil,
        "mergeIntent": nil,
      ],
      after: "merge"
    )

    let merged = try await persistence.snapshot().transition
    let approved = try XCTUnwrap(merged?.approvedSnipIDs)
    try await persistence.recordEnrollmentApproved(expected: approved)
    try trail.expect(["phase": "enrollmentApproved"], after: "enrollment")
    try await persistence.recordFirstSendStarted()
    try trail.expect(["phase": "firstSendStarted"], after: "first send started")

    try await persistence.recordSendAttempt(Self.attempt([Self.snipAOperation]))
    let firstSend = try Self.storedForm(Self.attempt([Self.snipAOperation]))
    try trail.expect(
      ["sendAttempt": firstSend, "pendingSettlementSnipIDs": [ID.snipA]],
      after: "send attempt"
    )
    try await persistence.recordSendAttempt(
      Self.attempt([Self.snipBOperation, Self.listOperation, Self.snipAOperation])
    )
    let mergedSend = try Self.storedForm(
      Self.attempt([Self.listOperation, Self.snipAOperation, Self.snipBOperation])
    )
    try trail.expect(
      ["sendAttempt": mergedSend, "pendingSettlementSnipIDs": [ID.snipA, ID.snipB]],
      after: "second send attempt"
    )

    try await persistence.recordFirstSendComplete()
    try trail.expect(["phase": "firstSendComplete"], after: "first send complete")
    try await persistence.swapPointer()
    try trail.expect(["phase": "pointerSwapped", "freezeToken": nil], after: "pointer swap")
    try await persistence.finishTransition()
    XCTAssertNil(try StoredTransitionTrail.transition(at: root), "finish")
  }

  func testUnfreezeAbsorbsAStoredMergeIntent() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = StoredManifestProbe(root: root)
    let persistence = try SwiftDataSyncModePersistence(
      rootURL: root,
      defaultSyncProtocol: .fullRecordV1,
      crashHook: probe.hit
    )
    _ = try await addSnip("seed", to: persistence)
    let frozen = try await freezeEnable(persistence)
    var trail = try StoredTransitionTrail(root: root)

    probe.failOnce(at: .beforeCandidateMergeDurability)
    do {
      _ = try await persistence.mergeFinalSnapshot(frozen.source, using: frozen.token)
      XCTFail("Expected the injected failure after the merge intent.")
    } catch StoredManifestProbe.Failure.injected {}
    let intended = try XCTUnwrap(StoredTransitionTrail.transition(at: root))
    let intent = try XCTUnwrap(intended["mergeIntent"] as? [String: Any])
    try trail.expect(intended, ["mergeIntent": intent], after: "merge intent")
    let superseded = StoredTransitionTrail.union(
      trail.last["supersededApprovedSnipIDs"],
      intent["approvedSnipIDs"]
    )

    try await persistence.unfreezeBeforePointerSwap(reason: .transitionFailure)

    try trail.expect(
      [
        "phase": "candidateReady",
        "freezeToken": nil,
        "freezeSnapshotTaken": false,
        "approvedSnipIDs": [String](),
        "mergeIntent": nil,
        "seedProvenance": intent["seedProvenance"],
        "seededListIDs": intent["seededListIDs"],
        "supersededApprovedSnipIDs": superseded,
        "pendingSettlementSnipIDs": [String](),
        "sendAttempt": nil,
      ],
      after: "unfreeze with a merge intent"
    )
  }

  func testRestartAfterFirstSendFailureKeepsSeedHistory() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try SwiftDataSyncModePersistence(
      rootURL: root,
      defaultSyncProtocol: .fullRecordV1
    )
    _ = try await addSnip("seed", to: persistence)
    let frozen = try await freezeEnable(persistence)
    try await startFirstSend(persistence, frozen)
    try await persistence.recordSendAttempt(Self.attempt([Self.snipAOperation]))
    var trail = try StoredTransitionTrail(root: root)
    XCTAssertEqual((trail.last["seedProvenance"] as? [Any])?.count, 1)
    let superseded = StoredTransitionTrail.union(
      trail.last["supersededApprovedSnipIDs"],
      trail.last["approvedSnipIDs"]
    )

    try await persistence.restartAfterFirstSendFailure(reason: nil, settlement: nil)

    try trail.expect(
      [
        "phase": "candidateReady",
        "freezeToken": nil,
        "freezeSnapshotTaken": false,
        "approvedSnipIDs": [String](),
        "supersededApprovedSnipIDs": superseded,
        "pendingSettlementSnipIDs": [String](),
        "sendAttempt": nil,
        "captureAcceptedServerProvenance": false,
      ],
      after: "restart after first-send failure"
    )
  }

  func testLegacyReadyCandidateWithoutSendIDsPreservesRetryEvidenceThroughCancel() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    _ = try await persistence.beginTransition(to: .iCloudSync, namespace: Self.binding)

    let tracked = try SwiftDataSyncModePersistence(rootURL: root)
    let trackedEvidence = await tracked.setupRetryEvidence(namespace: Self.binding)
    XCTAssertNil(trackedEvidence)

    // A legacy list-only send could return to candidateReady with no send attempt or snip IDs.
    let manifestURL = root.appendingPathComponent("activation.json")
    var legacy = try JSONDecoder().decode(
      SwiftDataSyncModePersistence.Manifest.self,
      from: Data(contentsOf: manifestURL)
    )
    let sourceIndex = try XCTUnwrap(legacy.stores.firstIndex { $0.id == legacy.activeStoreID })
    legacy.stores[sourceIndex].setupRetryHistory = nil
    try JSONEncoder().encode(legacy).write(to: manifestURL, options: .atomic)

    let reopened = try SwiftDataSyncModePersistence(rootURL: root)
    try await reopened.cancelPendingICloudEnable()
    let evidence = await reopened.setupRetryEvidence(namespace: Self.binding)
    let list = CloudSetupRetryRecordKey(
      reference: try XCTUnwrap(Self.listOperation.reference),
      identity: Self.listOperation.recordIdentity
    )
    XCTAssertTrue(try XCTUnwrap(evidence).requiresRecovery(for: list))

    let otherGeneration = ICloudSyncNamespaceBinding(
      scope: Self.binding.scope,
      accountLineage: Self.binding.accountLineage,
      generation: UUID(),
      zones: Self.binding.zones
    )
    let otherEvidence = await reopened.setupRetryEvidence(namespace: otherGeneration)
    XCTAssertNil(otherEvidence)
  }

  func testReopenAtSourceFrozenAwaitsCaptureUntilTheRetryFetchSettles() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try SwiftDataSyncModePersistence(
      rootURL: root,
      defaultSyncProtocol: .fullRecordV1
    )
    _ = try await addSnip("seed", to: persistence)
    _ = try await freezeEnable(persistence)
    var trail = try StoredTransitionTrail(root: root)

    let reopened = try SwiftDataSyncModePersistence(
      rootURL: root,
      defaultSyncProtocol: .fullRecordV1
    )
    try trail.expect(
      [
        "phase": "candidateReady",
        "freezeToken": nil,
        "freezeSnapshotTaken": false,
        "captureAcceptedServerProvenance": true,
      ],
      after: "reopen at sourceFrozen"
    )

    try await reopened.prepareRetryFetch(settlement: Self.emptySettlement)
    try trail.expect(
      ["captureAcceptedServerProvenance": false],
      after: "retry fetch settlement"
    )
  }

  func testReopenAtRecordsMergedSupersedesTheApprovedSeeds() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try SwiftDataSyncModePersistence(
      rootURL: root,
      defaultSyncProtocol: .fullRecordV1
    )
    _ = try await addSnip("seed", to: persistence)
    let frozen = try await freezeEnable(persistence)
    _ = try await persistence.mergeFinalSnapshot(frozen.source, using: frozen.token)
    var trail = try StoredTransitionTrail(root: root)
    let superseded = StoredTransitionTrail.union(
      trail.last["supersededApprovedSnipIDs"],
      trail.last["approvedSnipIDs"]
    )

    _ = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .fullRecordV1)

    try trail.expect(
      [
        "phase": "candidateReady",
        "freezeToken": nil,
        "freezeSnapshotTaken": false,
        "approvedSnipIDs": [String](),
        "supersededApprovedSnipIDs": superseded,
        "captureAcceptedServerProvenance": true,
      ],
      after: "reopen at recordsMerged"
    )
  }

  func testReopenDuringFirstSendKeepsTheSendForSettlement() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try SwiftDataSyncModePersistence(
      rootURL: root,
      defaultSyncProtocol: .fullRecordV1
    )
    _ = try await addSnip("seed", to: persistence)
    let frozen = try await freezeEnable(persistence)
    try await startFirstSend(persistence, frozen)
    try await persistence.recordSendAttempt(
      Self.attempt([Self.listOperation, Self.snipAOperation])
    )
    var trail = try StoredTransitionTrail(root: root)
    XCTAssertNotNil(trail.last["sendAttempt"])
    let superseded = StoredTransitionTrail.union(
      trail.last["supersededApprovedSnipIDs"],
      trail.last["approvedSnipIDs"]
    )

    let reopened = try SwiftDataSyncModePersistence(
      rootURL: root,
      defaultSyncProtocol: .fullRecordV1
    )
    try trail.expect(
      [
        "phase": "candidateReady",
        "freezeToken": nil,
        "freezeSnapshotTaken": false,
        "approvedSnipIDs": [String](),
        "supersededApprovedSnipIDs": superseded,
        "captureAcceptedServerProvenance": true,
      ],
      after: "reopen during the first send"
    )

    try await reopened.prepareRetryFetch(settlement: Self.emptySettlement)
    try trail.expect(
      [
        "captureAcceptedServerProvenance": false,
        "sendAttempt": nil,
        "pendingSettlementSnipIDs": [String](),
      ],
      after: "retry fetch settlement"
    )
  }

  func testOptOutWritersCarryAReopenedCaptureToTheEnd() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = StoredManifestProbe(root: root)
    let persistence = try SwiftDataSyncModePersistence(
      rootURL: root,
      defaultSyncProtocol: .fullRecordV1,
      crashHook: probe.hit
    )
    try await persistence.activateEmptyCollection(namespace: Self.binding)
    _ = try await addSnip("seed", to: persistence)
    let sourceStoreID = try await persistence.snapshot().activeStore.id

    let begun = try await persistence.beginTransition(to: .localOnly, namespace: nil)
    let declared = try XCTUnwrap(probe.transition(at: .afterCandidateManifest))
    let expectedDeclared = Self.declaredTransition(
      begun,
      sourceStoreID: sourceStoreID,
      targetFields: Self.optOutTargetFields
    )
    XCTAssertEqual(
      try Self.canonicalText(declared),
      try Self.canonical(Data(expectedDeclared.utf8))
    )
    var trail = StoredTransitionTrail(root: root, last: declared)
    try trail.expect(["phase": "candidateReady"], after: "begin")
    try await persistence.recordPreparationComplete()
    try trail.expect(["phase": "remoteFetched"], after: "preparation complete")
    let firstToken = try await persistence.freezeSource()
    let firstTokenForm = try Self.storedForm(firstToken)
    try trail.expect(["phase": "sourceFrozen", "freezeToken": firstTokenForm], after: "freeze")
    _ = try await persistence.finalSnapshot(using: firstToken)
    try trail.expect(["freezeSnapshotTaken": true], after: "final snapshot")

    let reopened = try SwiftDataSyncModePersistence(
      rootURL: root,
      defaultSyncProtocol: .fullRecordV1,
      crashHook: probe.hit
    )
    try trail.expect(
      [
        "phase": "candidateReady",
        "freezeToken": nil,
        "freezeSnapshotTaken": false,
        "captureAcceptedServerProvenance": true,
      ],
      after: "reopen"
    )

    try await reopened.recordPreparationComplete()
    try trail.expect(["phase": "remoteFetched"], after: "preparation complete after reopen")
    let token = try await reopened.freezeSource()
    let tokenForm = try Self.storedForm(token)
    try trail.expect(
      ["phase": "sourceFrozen", "freezeToken": tokenForm],
      after: "freeze after reopen"
    )
    let source = try await reopened.finalSnapshot(using: token)
    try trail.expect(["freezeSnapshotTaken": true], after: "final snapshot after reopen")
    _ = try await reopened.mergeFinalSnapshot(source, using: token)
    let intended = try XCTUnwrap(probe.transition(at: .beforeCandidateMergeDurability))
    let intent = try XCTUnwrap(intended["mergeIntent"] as? [String: Any])
    try trail.expect(intended, ["mergeIntent": intent], after: "merge intent")
    try trail.expect(
      [
        "phase": "recordsMerged",
        "approvedSnipIDs": intent["approvedSnipIDs"],
        "seedProvenance": intent["seedProvenance"],
        "seededListIDs": intent["seededListIDs"],
        "pendingSettlementSnipIDs": [String](),
        "sendAttempt": nil,
        "mergeIntent": nil,
      ],
      after: "merge"
    )

    let merged = try await reopened.snapshot().transition
    let approved = try XCTUnwrap(merged?.approvedSnipIDs)
    try await reopened.recordEnrollmentApproved(expected: approved)
    try trail.expect(["phase": "enrollmentApproved"], after: "enrollment")
    try await reopened.recordNoSendRequired()
    try trail.expect(["phase": "firstSendComplete"], after: "no send required")
    try await reopened.swapPointer()
    try trail.expect(["phase": "pointerSwapped", "freezeToken": nil], after: "pointer swap")
    XCTAssertEqual(trail.last["captureAcceptedServerProvenance"] as? Bool, true)
    try await reopened.finishTransition()
    XCTAssertNil(try StoredTransitionTrail.transition(at: root), "finish")
  }

  // MARK: Driving the writers

  /// Begins an enable and takes its final snapshot.
  private func freezeEnable(
    _ persistence: SwiftDataSyncModePersistence
  ) async throws -> (token: SyncModeFreezeToken, source: SnipLibraryTransferSnapshot) {
    _ = try await persistence.beginTransition(to: .iCloudSync, namespace: Self.binding)
    try await persistence.recordPreparationComplete()
    let token = try await persistence.freezeSource()
    let source = try await persistence.finalSnapshot(using: token)
    return (token, source)
  }

  /// Merges a frozen enable, approves its seeds, and starts its first send.
  private func startFirstSend(
    _ persistence: SwiftDataSyncModePersistence,
    _ frozen: (token: SyncModeFreezeToken, source: SnipLibraryTransferSnapshot)
  ) async throws {
    _ = try await persistence.mergeFinalSnapshot(frozen.source, using: frozen.token)
    let merged = try await persistence.snapshot().transition
    let approved = try XCTUnwrap(merged?.approvedSnipIDs)
    try await persistence.recordEnrollmentApproved(expected: approved)
    try await persistence.recordFirstSendStarted()
  }

  private func addSnip(
    _ content: String,
    to persistence: SwiftDataSyncModePersistence
  ) async throws -> Snip {
    let requestID = UUID()
    let update = try await persistence.activeLibrary().perform(
      .add(
        content: content,
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [],
        requestID: requestID,
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )
    return try XCTUnwrap(update.snapshot.snips.first { $0.requestID == requestID })
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "SyncModeTransitionStoredFormTests-\(UUID().uuidString)",
      isDirectory: true
    )
  }

  private static let binding = ICloudSyncNamespaceBinding(
    scope: "private",
    accountLineage: "account",
    generation: UUID(uuidString: ID.generation)!,
    zones: [
      ICloudSyncZoneBinding(name: "metadata", ownerName: "owner"),
      ICloudSyncZoneBinding(name: "payload", ownerName: "owner"),
    ]
  )

  private static let emptySettlement = SyncModeSeedSettlementProof(namespace: binding, values: [:])

  private static let listOperation = operation(
    .list, ID.list, record: "list-1", zone: "metadata", .save
  )
  private static let snipAOperation = operation(
    .snip, ID.snipA, record: "snip-a", zone: "metadata", .save
  )
  private static let snipBOperation = operation(
    .snip, ID.snipB, record: "snip-b", zone: "payload", .delete
  )

  private static func operation(
    _ kind: CloudEntityKind,
    _ domainID: String,
    record: String,
    zone: String,
    _ change: SyncModeSendOperationKind
  ) -> SyncModeSendOperation {
    SyncModeSendOperation(
      reference: CloudEntityReference(kind: kind, domainID: UUID(uuidString: domainID)!),
      recordIdentity: CloudTextStorageIdentity(
        zoneName: zone,
        ownerName: "owner",
        recordName: record
      ),
      kind: change
    )
  }

  private static func attempt(_ operations: [SyncModeSendOperation]) -> SyncModeSendAttempt {
    SyncModeSendAttempt(namespace: binding, operations: operations)
  }

  // MARK: Stored fixtures

  private enum ID {
    static let transition = "10000000-0000-0000-0000-000000000001"
    static let sourceStore = "20000000-0000-0000-0000-000000000002"
    static let candidateStore = "30000000-0000-0000-0000-000000000003"
    static let freezeToken = "40000000-0000-0000-0000-000000000004"
    static let snipA = "50000000-0000-0000-0000-000000000005"
    static let snipB = "60000000-0000-0000-0000-000000000006"
    static let sourceSnipB = "61000000-0000-0000-0000-000000000006"
    static let requestA = "70000000-0000-0000-0000-000000000007"
    static let requestB = "71000000-0000-0000-0000-000000000007"
    static let list = "80000000-0000-0000-0000-000000000008"
    static let seededList = "81000000-0000-0000-0000-000000000008"
    static let intent = "90000000-0000-0000-0000-000000000009"
    static let supersededSnip = "A0000000-0000-0000-0000-00000000000A"
    static let generation = "99999999-9999-9999-9999-999999999999"
  }

  private enum Target { case enable, optOut }
  private enum History { case empty, earlierAttempts }

  /// One stored transition per shape a build writes.
  private static var storedShapes: [(String, String)] {
    [
      ("candidateDeclared", transition("candidateDeclared", history: .empty)),
      ("candidateReady", transition("candidateReady")),
      ("remoteFetched", transition("remoteFetched")),
      (
        "sourceFrozen before the final snapshot",
        transition("sourceFrozen", freezeToken: storedToken)
      ),
      (
        "sourceFrozen after the final snapshot",
        transition("sourceFrozen", freezeToken: storedToken, freezeSnapshotTaken: true)
      ),
      (
        "sourceFrozen with a legacy merge intent",
        transition(
          "sourceFrozen",
          freezeToken: storedToken,
          freezeSnapshotTaken: true,
          mergeIntent: mergeIntent(fullReenablePlanID: nil)
        )
      ),
      (
        "sourceFrozen with a full re-enable merge intent",
        transition(
          "sourceFrozen",
          freezeToken: storedToken,
          freezeSnapshotTaken: true,
          mergeIntent: mergeIntent(fullReenablePlanID: ID.transition)
        )
      ),
      (
        "recordsMerged",
        transition(
          "recordsMerged",
          freezeToken: storedToken,
          freezeSnapshotTaken: true,
          approvedSnipIDs: approvedSnipIDs
        )
      ),
      (
        "enrollmentApproved",
        transition(
          "enrollmentApproved",
          freezeToken: storedToken,
          freezeSnapshotTaken: true,
          approvedSnipIDs: approvedSnipIDs
        )
      ),
      (
        "firstSendStarted",
        transition(
          "firstSendStarted",
          freezeToken: storedToken,
          freezeSnapshotTaken: true,
          approvedSnipIDs: approvedSnipIDs
        )
      ),
      (
        "firstSendStarted with a recorded send",
        transition(
          "firstSendStarted",
          freezeToken: storedToken,
          freezeSnapshotTaken: true,
          approvedSnipIDs: approvedSnipIDs,
          sendAttempt: recordedSend,
          pendingSettlementSnipIDs: recordedSendSnipIDs
        )
      ),
      (
        "firstSendComplete",
        transition(
          "firstSendComplete",
          freezeToken: storedToken,
          freezeSnapshotTaken: true,
          approvedSnipIDs: approvedSnipIDs
        )
      ),
      (
        "firstSendComplete with a recorded send",
        transition(
          "firstSendComplete",
          freezeToken: storedToken,
          freezeSnapshotTaken: true,
          approvedSnipIDs: approvedSnipIDs,
          sendAttempt: recordedSend,
          pendingSettlementSnipIDs: recordedSendSnipIDs
        )
      ),
      (
        "pointerSwapped",
        transition("pointerSwapped", freezeSnapshotTaken: true, approvedSnipIDs: approvedSnipIDs)
      ),
      (
        "pointerSwapped with a recorded send",
        transition(
          "pointerSwapped",
          freezeSnapshotTaken: true,
          approvedSnipIDs: approvedSnipIDs,
          sendAttempt: recordedSend,
          pendingSettlementSnipIDs: recordedSendSnipIDs
        )
      ),
      (
        "candidateReady awaiting capture of a recorded send",
        transition(
          "candidateReady",
          sendAttempt: recordedSend,
          pendingSettlementSnipIDs: recordedSendSnipIDs,
          captureAcceptedServerProvenance: true
        )
      ),
      (
        "candidateReady awaiting capture without a send",
        transition("candidateReady", captureAcceptedServerProvenance: true)
      ),
      (
        "reopened opt-out at remoteFetched",
        transition("remoteFetched", target: .optOut, captureAcceptedServerProvenance: true)
      ),
      (
        "reopened opt-out at sourceFrozen with a merge intent",
        transition(
          "sourceFrozen",
          target: .optOut,
          freezeToken: storedToken,
          freezeSnapshotTaken: true,
          mergeIntent: mergeIntent(fullReenablePlanID: nil),
          captureAcceptedServerProvenance: true
        )
      ),
      (
        "reopened opt-out at recordsMerged",
        transition(
          "recordsMerged",
          target: .optOut,
          freezeToken: storedToken,
          freezeSnapshotTaken: true,
          approvedSnipIDs: approvedSnipIDs,
          captureAcceptedServerProvenance: true
        )
      ),
      (
        "reopened opt-out at enrollmentApproved",
        transition(
          "enrollmentApproved",
          target: .optOut,
          freezeToken: storedToken,
          freezeSnapshotTaken: true,
          approvedSnipIDs: approvedSnipIDs,
          captureAcceptedServerProvenance: true
        )
      ),
      (
        "reopened opt-out at firstSendComplete",
        transition(
          "firstSendComplete",
          target: .optOut,
          freezeToken: storedToken,
          freezeSnapshotTaken: true,
          approvedSnipIDs: approvedSnipIDs,
          captureAcceptedServerProvenance: true
        )
      ),
      (
        "reopened opt-out at pointerSwapped",
        transition(
          "pointerSwapped",
          target: .optOut,
          freezeSnapshotTaken: true,
          approvedSnipIDs: approvedSnipIDs,
          captureAcceptedServerProvenance: true
        )
      ),
    ]
  }

  /// A stored transition object. Optional keys are written only when present, as the encoder does.
  private static func transition(
    _ phase: String,
    target: Target = .enable,
    freezeToken: String? = nil,
    freezeSnapshotTaken: Bool = false,
    approvedSnipIDs: String = "[]",
    mergeIntent: String? = nil,
    sendAttempt: String? = nil,
    pendingSettlementSnipIDs: String = "[]",
    captureAcceptedServerProvenance: Bool = false,
    history: History = .earlierAttempts
  ) -> String {
    var fields = [
      ("id", quoted(ID.transition)),
      ("sourceStoreID", quoted(ID.sourceStore)),
      ("candidateStoreID", quoted(ID.candidateStore)),
      ("phase", quoted(phase)),
      ("freezeSnapshotTaken", "\(freezeSnapshotTaken)"),
      ("approvedSnipIDs", approvedSnipIDs),
      ("pendingSettlementSnipIDs", pendingSettlementSnipIDs),
      ("captureAcceptedServerProvenance", "\(captureAcceptedServerProvenance)"),
    ]
    switch target {
    case .enable:
      fields += [
        ("targetKind", quoted("iCloudSync")),
        ("namespace", namespace),
        ("syncProtocol", quoted("fullRecordV1")),
      ]
    case .optOut:
      fields += [("targetKind", quoted("localOnly")), ("syncProtocol", quoted("fullRecordV1"))]
    }
    switch history {
    case .empty:
      fields += [
        ("seedProvenance", "[]"),
        ("seededListIDs", "[]"),
        ("serverAcceptedSeedSnipIDs", "[]"),
        ("supersededApprovedSnipIDs", "[]"),
      ]
    case .earlierAttempts:
      fields += [
        ("seedProvenance", seedProvenance),
        ("seededListIDs", list([ID.list, ID.seededList])),
        ("serverAcceptedSeedSnipIDs", list([ID.snipA, ID.snipB])),
        ("supersededApprovedSnipIDs", list([ID.supersededSnip, ID.snipB])),
      ]
    }
    if let freezeToken { fields.append(("freezeToken", freezeToken)) }
    if let mergeIntent { fields.append(("mergeIntent", mergeIntent)) }
    if let sendAttempt { fields.append(("sendAttempt", sendAttempt)) }
    return object(fields)
  }

  /// What `beginTransition` writes first: the declared candidate with no history.
  private static func declaredTransition(
    _ transition: SyncModeTransition,
    sourceStoreID: UUID,
    targetFields: String
  ) -> String {
    """
    {
      "approvedSnipIDs": [],
      "candidateStoreID": "\(transition.candidateStoreID.uuidString)",
      "captureAcceptedServerProvenance": false,
      "freezeSnapshotTaken": false,
      "id": "\(transition.id.uuidString)",
      "pendingSettlementSnipIDs": [],
      "phase": "candidateDeclared",
      "seedProvenance": [],
      "seededListIDs": [],
      "serverAcceptedSeedSnipIDs": [],
      "sourceStoreID": "\(sourceStoreID.uuidString)",
      "supersededApprovedSnipIDs": [],
      \(targetFields)
    }
    """
  }

  private static let enableTargetFields =
    #""namespace": \#(namespace), "syncProtocol": "fullRecordV1", "targetKind": "iCloudSync""#
  private static let optOutTargetFields = #""syncProtocol": "fullRecordV1", "targetKind": "localOnly""#

  private static let namespace = """
    {
      "accountLineage": "account",
      "generation": "\(ID.generation)",
      "scope": "private",
      "zones": [
        {"name": "metadata", "ownerName": "owner"},
        {"name": "payload", "ownerName": "owner"}
      ]
    }
    """

  private static let storedToken = """
    {"id": "\(ID.freezeToken)", "revision": 7, "sourceStoreID": "\(ID.sourceStore)"}
    """

  private static let approvedSnipIDs = list([ID.snipA, ID.snipB])

  /// Ordered by candidate snip ID, as the merge stores it.
  private static let seedProvenance = """
    [
      {
        "acceptedRecordIdentity": {"ownerName": "owner", "recordName": "snip-a", "zoneName": "metadata"},
        "baseDigest": "ERERERERERERERERERERERERERERERERERERERERERE=",
        "baseRemoteDigest": "IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI=",
        "candidateRequestID": "\(ID.requestA)",
        "candidateSnipID": "\(ID.snipA)",
        "digestVersion": 3,
        "sourceSnipID": "\(ID.snipA)"
      },
      {
        "baseDigest": "MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM=",
        "baseRemoteDigest": "REREREREREREREREREREREREREREREREREREREREREQ=",
        "candidateRequestID": "\(ID.requestB)",
        "candidateSnipID": "\(ID.snipB)",
        "digestVersion": 2,
        "sourceSnipID": "\(ID.sourceSnipB)"
      }
    ]
    """

  private static func mergeIntent(fullReenablePlanID: String?) -> String {
    var fields = [
      ("approvedSnipIDs", approvedSnipIDs),
      ("id", quoted(ID.intent)),
      ("planDigest", quoted("q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s=")),
      ("recoveredSourceSnipIDs", list([ID.sourceSnipB])),
      ("seedProvenance", seedProvenance),
      ("seededListIDs", list([ID.list, ID.seededList])),
      ("sourceRevision", "7"),
    ]
    if let fullReenablePlanID {
      fields.append(("fullReenablePlanID", quoted(fullReenablePlanID)))
    }
    return object(fields)
  }

  private static let recordedSend = sendAttemptJSON(snipAKey: snipAReferenceKey)
  private static let recordedSendSnipIDs = list([ID.snipA, ID.snipB])
  private static let snipAReferenceKey =
    #""reference": {"domainID": "\#(ID.snipA)", "kind": "snip"}"#
  /// Builds before typed references stored a snip operation's ID under `snipID`.
  private static let legacySnipAKey = #""snipID": "\#(ID.snipA)""#

  /// Operations ordered as `recordSendAttempt` stores them: by reference kind, then domain ID.
  private static func sendAttemptJSON(snipAKey: String) -> String {
    """
    {
      "namespace": \(namespace),
      "operations": [
        {
          "kind": "save",
          "recordIdentity": {"ownerName": "owner", "recordName": "list-1", "zoneName": "metadata"},
          "reference": {"domainID": "\(ID.list)", "kind": "list"}
        },
        {
          "kind": "save",
          "recordIdentity": {"ownerName": "owner", "recordName": "snip-a", "zoneName": "metadata"},
          \(snipAKey)
        },
        {
          "kind": "delete",
          "recordIdentity": {"ownerName": "owner", "recordName": "snip-b", "zoneName": "payload"},
          "reference": {"domainID": "\(ID.snipB)", "kind": "snip"}
        }
      ]
    }
    """
  }

  private static func quoted(_ value: String) -> String { "\"\(value)\"" }

  private static func list(_ values: [String]) -> String {
    "[" + values.map(quoted).joined(separator: ", ") + "]"
  }

  private static func object(_ fields: [(String, String)]) -> String {
    "{" + fields.map { "\(quoted($0.0)): \($0.1)" }.joined(separator: ", ") + "}"
  }

  // MARK: Comparing stored JSON

  /// Keys whose arrays encode a `Set`, so their order means nothing.
  private static let setValuedKeys: Set<String> = [
    "approvedSnipIDs", "pendingSettlementSnipIDs", "supersededApprovedSnipIDs",
    "serverAcceptedSeedSnipIDs", "seededListIDs", "recoveredSourceSnipIDs", "zones",
  ]

  private static func encoded(_ transition: SyncModeTransition) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(transition)
  }

  /// The JSON form a stored value takes.
  private static func storedForm<Value: Encodable>(_ value: Value) throws -> Any {
    try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(value),
      options: .fragmentsAllowed
    )
  }

  private static func canonical(_ json: Data) throws -> String {
    try canonicalText(JSONSerialization.jsonObject(with: json, options: .fragmentsAllowed))
  }

  /// JSON text with sorted keys and sorted set-valued arrays, so equal stored forms compare equal.
  /// Pass `key` when `value` is that key's value, so a set-valued array sorts at the top too.
  fileprivate static func canonicalText(_ value: Any, under key: String? = nil) throws -> String {
    let data = try JSONSerialization.data(
      withJSONObject: sortingSets(value, under: key),
      options: [.sortedKeys, .fragmentsAllowed]
    )
    return String(decoding: data, as: UTF8.self)
  }

  private static func sortingSets(_ value: Any, under key: String?) throws -> Any {
    if let object = value as? [String: Any] {
      var sorted: [String: Any] = [:]
      for (childKey, child) in object {
        sorted[childKey] = try sortingSets(child, under: childKey)
      }
      return sorted
    }
    guard let array = value as? [Any] else { return value }
    let elements = try array.map { try sortingSets($0, under: nil) }
    guard let key, setValuedKeys.contains(key) else { return elements }
    return try elements
      .map { (text: try canonicalText($0), value: $0) }
      .sorted { $0.text < $1.text }
      .map { $0.value }
  }
}

/// Follows the stored `transition` object in `activation.json` from one writer call to the next.
private struct StoredTransitionTrail {
  let root: URL
  private(set) var last: [String: Any]

  init(root: URL, last: [String: Any]) {
    self.root = root
    self.last = last
  }

  init(root: URL) throws {
    let stored = try XCTUnwrap(Self.transition(at: root), "No stored transition")
    self.init(root: root, last: stored)
  }

  static func transition(at root: URL) throws -> [String: Any]? {
    try transition(in: Data(contentsOf: root.appendingPathComponent("activation.json")))
  }

  static func transition(in manifest: Data) throws -> [String: Any]? {
    let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any]
    return object?["transition"] as? [String: Any]
  }

  /// The sorted union of stored ID arrays.
  static func union(_ values: Any?...) -> [String] {
    Set(values.flatMap { $0 as? [String] ?? [] }).sorted()
  }

  /// Checks that the stored transition now holds `changes` and that every other key kept its
  /// value since the last check. A nil change means the key is absent. A listed key may also
  /// keep its value.
  mutating func expect(
    _ changes: [String: Any?],
    after step: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let current = try XCTUnwrap(
      Self.transition(at: root),
      "\(step): no stored transition",
      file: file,
      line: line
    )
    try expect(current, changes, after: step, file: file, line: line)
  }

  /// Checks `current`, a transition read earlier, the same way.
  mutating func expect(
    _ current: [String: Any],
    _ changes: [String: Any?],
    after step: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    for key in Set(last.keys).union(current.keys).union(changes.keys).sorted() {
      let expected: Any?
      if let change = changes[key] {
        expected = change
      } else {
        expected = last[key]
      }
      XCTAssertEqual(
        try Self.text(of: current[key], under: key),
        try Self.text(of: expected, under: key),
        "\(step): \(key)",
        file: file,
        line: line
      )
    }
    last = current
  }

  private static func text(of value: Any?, under key: String) throws -> String {
    guard let value else { return "absent" }
    return try SyncModeTransitionStoredFormTests.canonicalText(value, under: key)
  }
}

/// Copies `activation.json` at every crash point, and can fail once at one of them.
private final class StoredManifestProbe: @unchecked Sendable {
  enum Failure: Error { case injected }

  private let lock = NSLock()
  private let manifestURL: URL
  private var captures: [(point: SyncModeCrashPoint, manifest: Data)] = []
  private var failurePoint: SyncModeCrashPoint?

  init(root: URL) {
    manifestURL = root.appendingPathComponent("activation.json", isDirectory: false)
  }

  func failOnce(at point: SyncModeCrashPoint) {
    lock.withLock { failurePoint = point }
  }

  func hit(_ point: SyncModeCrashPoint) throws {
    let manifest = try? Data(contentsOf: manifestURL)
    let fails = lock.withLock { () -> Bool in
      if let manifest { captures.append((point, manifest)) }
      guard failurePoint == point else { return false }
      failurePoint = nil
      return true
    }
    if fails { throw Failure.injected }
  }

  /// The stored transition at the latest visit to `point`.
  func transition(at point: SyncModeCrashPoint) throws -> [String: Any]? {
    let manifest = lock.withLock { captures.last(where: { $0.point == point })?.manifest }
    return try manifest.flatMap(StoredTransitionTrail.transition(in:))
  }
}
