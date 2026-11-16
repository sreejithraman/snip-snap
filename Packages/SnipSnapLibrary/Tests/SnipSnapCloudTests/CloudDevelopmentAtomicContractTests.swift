#if DEBUG
import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence
import Synchronization
import XCTest
@_spi(Maintainer) @testable import SnipSnapCloud

final class CloudDevelopmentAtomicContractTests: XCTestCase {
  func testObserverPreservesPendingOperationsAndFetchAndSendOptionsAndErrors() async throws {
    let f = try ObserverFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.transport.start(state: nil)
    let observer = try f.observer()
    let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(f.id)
    observer.add(pendingRecordZoneChanges: [pending])
    XCTAssertEqual(f.base.pendingRecordZoneChanges, [pending])
    XCTAssertEqual(observer.pendingRecordZoneChanges, [pending])
    let zoneChange = CKSyncEngine.PendingDatabaseChange.saveZone(CKRecordZone(zoneID: f.id.zoneID))
    observer.add(pendingDatabaseChanges: [zoneChange])
    XCTAssertEqual(observer.pendingDatabaseChanges, [zoneChange])
    observer.remove(pendingDatabaseChanges: [zoneChange])
    XCTAssertTrue(f.base.pendingDatabaseChanges.isEmpty)
    observer.remove(pendingRecordZoneChanges: [pending])
    XCTAssertTrue(f.base.pendingRecordZoneChanges.isEmpty)
    var fetch = CKSyncEngine.FetchChangesOptions(); fetch.scope = .zoneIDs([f.id.zoneID])
    try await observer.fetchChanges(fetch)
    XCTAssertEqual(f.base.state.withLock { $0.fetches.map(\.scope) }, [fetch.scope])
    f.base.state.withLock { $0.failFetch = true }
    do { try await observer.fetchChanges(fetch); XCTFail("The exact fetch error must escape") }
    catch { XCTAssertTrue((error as NSError) === f.base.failure) }
    let send = CKSyncEngine.SendChangesOptions()
    do { try await observer.sendChanges(send); XCTFail("The exact underlying error must escape") }
    catch { XCTAssertTrue((error as NSError) === f.base.failure) }
    XCTAssertEqual(f.base.state.withLock { $0.sends.map(\.scope) }, [send.scope])
    let trace = try f.evidence.entries()
    XCTAssertEqual(trace.filter { $0.kind == "send-throw:-1" }.count, 1)
    XCTAssertEqual(trace.filter { $0.kind == "fetch-throw" }.count, 1)
    XCTAssertFalse(trace.contains { $0.kind == "send-return" || $0.kind == "sent-event-before" })
    await f.transport.reset()
  }

  func testObserverIdentityForwardsRealProviderAndTerminalEventsWhileBaseIdentityIsRejected() async throws {
    let f = try ObserverFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.transport.start(state: nil)
    let observer = try f.observer()
    // A callback forwarded as the underlying engine is stale/foreign to the transport.
    await f.transport.handle(.accountChange, from: f.base)
    let ignored = await f.transport.contractHeadEvent()
    XCTAssertNil(ignored)
    try await f.confirmInitialFetchEvents()
    let fetchOptions = await observer.fetchOptions()
    XCTAssertEqual(fetchOptions.scope, .zoneIDs([f.id.zoneID]))
    let draft = CloudRecordDraft.text(id: CloudKitRecordMapper.id(for: f.id), snipID: UUID(), text: "literal original")
    try await f.transport.scheduleAutomaticSync(CloudOutboundBatch(operations: [.save(draft)]))
    await observer.forward(.willSendChanges)
    let foreign = await f.transport.nextRecordZoneChangeBatch(scope: .all, from: f.base)
    XCTAssertNil(foreign)
    let supplied = await observer.batch(scope: .all)
    let batch = try XCTUnwrap(supplied)
    XCTAssertEqual(batch.recordsToSave.map(\.recordID), [f.id])
    XCTAssertEqual(batch.recordsToSave.first?.encryptedValues["text"] as? String, "literal original")
    await observer.forward(.sentRecordZoneChanges(savedRecords: batch.recordsToSave, deletedRecordIDs: [],
      failedRecordSaves: [], failedRecordDeletes: []))
    await observer.forward(.didSendChanges)
    var saved: [CloudRecordSnapshot] = []
    while let event = await f.transport.contractHeadEvent() {
      if case .batch(let pending) = event, case .sent(let sent) = pending.batch {
        saved += sent.items.compactMap { if case .saved(let value) = $0 { value } else { nil } }
      }
      try await f.transport.confirmApplied(event.id)
    }
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved.first?.encryptedFields["text"], .string("literal original"))
    try await f.transport.scheduleAutomaticSync(CloudOutboundBatch(operations: [.save(draft)]))
    await observer.forward(.willSendChanges)
    let retried = await observer.batch(scope: .all)
    XCTAssertEqual(retried?.recordsToSave.map(\.recordID), [f.id])
    await observer.forward(.sentRecordZoneChanges(savedRecords: [], deletedRecordIDs: [],
      failedRecordSaves: [(recordID: f.id, error: CKError(.unknownItem))], failedRecordDeletes: []))
    await observer.forward(.didSendChanges)
    var unknown: [CloudRecordID] = []
    while let event = await f.transport.contractHeadEvent() {
      if case .batch(let pending) = event, case .sent(let sent) = pending.batch {
        unknown += sent.items.compactMap { if case .unknownItem(let id) = $0 { id } else { nil } }
      }
      try await f.transport.confirmApplied(event.id)
    }
    XCTAssertEqual(unknown, [draft.id])
    let trace = try f.evidence.entries()
    try CloudDevelopmentAtomicContract.eventsMatchBatches(trace)
    XCTAssertEqual(trace.filter { $0.kind == "sent-event-before" }.count, 2)
    XCTAssertEqual(trace.filter { $0.kind == "sent-event-after" }.count, 2)
    XCTAssertEqual(trace.last { $0.kind == "sent-event-before" }?.errors.values.first, CKError.Code.unknownItem.rawValue)
    await f.transport.reset()
    await observer.forward(.accountChange)
    let afterReset = await f.transport.contractHeadEvent()
    XCTAssertNil(afterReset)
  }

  func testFailureOracleRejectsPartialSuccessMissingServerRecordAndForeignConflict() throws {
    let ids = ["A", "B", "C", "D"]
    let conflict = CKError.Code.serverRecordChanged.rawValue
    let shortCircuit = CKError.Code.batchRequestFailed.rawValue
    let errors = ["A": conflict, "B": shortCircuit, "C": shortCircuit, "D": shortCircuit]
    let valid = entry("sent-event-before", ids: ids, errors: errors, tags: ["A": "server-tag-hash"])
    try CloudDevelopmentAtomicContract.failedGroup([valid], ids: ids, stale: ["A"], expectedTags: ["A": "server-tag-hash"])
    XCTAssertThrowsError(try CloudDevelopmentAtomicContract.failedGroup([
      entry("sent-event-before", ids: ids, errors: errors)], ids: ids, stale: ["A"], expectedTags: ["A": "server-tag-hash"]))
    XCTAssertThrowsError(try CloudDevelopmentAtomicContract.failedGroup([valid], ids: ids, stale: ["B"], expectedTags: ["A": "server-tag-hash"]))
    var partial = errors; partial.removeValue(forKey: "D")
    XCTAssertThrowsError(try CloudDevelopmentAtomicContract.failedGroup([
      entry("sent-event-before", ids: ids, errors: partial, tags: ["A": "server-tag-hash"])], ids: ids, stale: ["A"], expectedTags: ["A": "server-tag-hash"]))
    XCTAssertThrowsError(try CloudDevelopmentAtomicContract.failedGroup([valid, valid], ids: ids, stale: ["A"], expectedTags: ["A": "server-tag-hash"]))
  }

  func testObserverReturnsAtomicGroupWithoutAddingForeignPendingRecordOrChangingItsBodies() async throws {
    let f = try ObserverFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.transport.start(state: nil)
    let observer = try f.observer()
    try await f.confirmInitialFetchEvents()
    let drafts = (0..<3).map { index in
      let uuid = CloudDevelopmentAtomicContract.snip(100 + index).uuidString.lowercased()
      return CloudRecordDraft(id: CloudRecordID(zone: CloudKitRecordMapper.id(for: f.id).zone, name: "a-\(uuid)"),
        recordType: "AttachmentMetadata", schemaVersion: 1, routingFields: ["schemaVersion": .int64(1)],
        encryptedFields: ["snipID": .string("00000000-0000-0000-0000-000000000001"),
          "attachmentID": .string(uuid), "position": .int64(Int64(index)),
          "fileName": .string("original-\(index).txt"), "contentType": .string("public.plain-text"),
          "byteCount": .int64(1), "sha256": .data(Data(repeating: UInt8(index), count: 32)),
          "payloadZoneName": .string(f.id.zoneID.zoneName), "payloadOwnerName": .string("owner"),
          "payloadRecordName": .string("synthetic-payload-\(index)")])
    }
    try await f.transport.scheduleAutomaticSync(CloudOutboundBatch(operations: drafts.map(CloudOutboundOperation.save)))
    let foreign = CKRecord.ID(recordName: "not-submitted", zoneID: f.id.zoneID)
    f.base.add(pendingRecordZoneChanges: [.saveRecord(foreign)])
    await observer.forward(.willSendChanges)
    let supplied = await observer.batch(scope: .all)
    let batch = try XCTUnwrap(supplied)
    XCTAssertTrue(batch.atomicByZone)
    XCTAssertEqual(Set(batch.recordsToSave.map(\.recordID)), Set(drafts.map { CloudKitRecordMapper.recordID(for: $0.id) }))
    XCTAssertTrue(batch.recordIDsToDelete.isEmpty)
    for draft in drafts {
      let record = try XCTUnwrap(batch.recordsToSave.first { CloudKitRecordMapper.id(for: $0.recordID) == draft.id })
      XCTAssertEqual(try CloudKitRecordMapper.snapshot(record).encryptedFields, draft.encryptedFields)
    }
    XCTAssertTrue(observer.pendingRecordZoneChanges.contains(.saveRecord(foreign)))
    await f.transport.reset()
  }

  func testEventOracleRejectsCrossedGroupsMissingAndExtraCallbacks() throws {
    let first = entry("provider-batch", ids: ["A", "B"])
    let second = entry("provider-batch", ids: ["C", "D"])
    let a = entry("sent-event-before", ids: ["A", "B"])
    let b = entry("sent-event-before", ids: ["C", "D"])
    try CloudDevelopmentAtomicContract.eventsMatchBatches([first, a, second, b])
    try CloudDevelopmentAtomicContract.eventsMatchBatches([first, b, second, a])
    XCTAssertThrowsError(try CloudDevelopmentAtomicContract.eventsMatchBatches([first,
      entry("sent-event-before", ids: ["A", "C"]), second, entry("sent-event-before", ids: ["B", "D"])]))
    XCTAssertThrowsError(try CloudDevelopmentAtomicContract.eventsMatchBatches([first]))
    XCTAssertThrowsError(try CloudDevelopmentAtomicContract.eventsMatchBatches([first, a, a]))
  }

  func testLiteralOracleRejectsMatchingButIncorrectOrderNameTypeAndMembership() throws {
    let zone = CloudZoneID(name: "oracle", ownerName: "owner")
    let ids = ["a", "b", "c", "d"].map { CloudRecordID(zone: zone, name: $0) }
    let positions = [1, 0, 2, 3]
    let values = try ids.indices.map { i in
      try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: CloudRecordDraft(id: ids[i],
        recordType: "AttachmentMetadata", schemaVersion: 1, routingFields: [:],
        encryptedFields: ["position": .int64(Int64(positions[i])), "fileName": .string(["A.txt", "B.txt", "C.txt", "D.txt"][i]),
          "contentType": .string("public.plain-text")])))
    }
    try CloudDevelopmentAtomicContract.literalOrder(values, ids: ids, expected: [1, 0, 2, 3])
    XCTAssertThrowsError(try CloudDevelopmentAtomicContract.literalOrder(values, ids: ids, expected: [0, 1, 2, 3]))
    for field in ["fileName", "contentType"] {
      let record = try values[0].shadow.record(); record.encryptedValues[field] = "wrong"
      var corrupt = values; corrupt[0] = try CloudKitRecordMapper.snapshot(record)
      XCTAssertThrowsError(try CloudDevelopmentAtomicContract.literalOrder(corrupt, ids: ids, expected: [1, 0, 2, 3]))
    }
    XCTAssertThrowsError(try CloudDevelopmentAtomicContract.literalOrder(Array(values.dropLast()), ids: ids, expected: [1, 0, 2, 3]))
  }

  func testCleanupAttemptsEveryExactZoneDespiteFirstFailureAndPartialCreation() async throws {
    let zones = ["first", "never-created", "last"].map { CloudZoneID(name: "snipsnap-contract-\($0)", ownerName: "owner") }
    let calls = Mutex<[String]>([])
    let outcomes = Mutex<[String: Bool]>([:])
    do {
      try await CloudDevelopmentTransportContract.cleanupZones(zones, validateAccount: {}, delete: { zone in
        calls.withLock { $0.append(zone.name) }
        if zone == zones[0] { throw ProbeFailure.delete }
      }, exists: { $0 == zones[0] }, didFinish: { zone, success in outcomes.withLock { $0[zone.name] = success } })
      XCTFail("An unresolved first zone must remain a failure")
    } catch {
      XCTAssertTrue(String(describing: error).contains(zones[0].name))
    }
    XCTAssertEqual(calls.withLock { $0 }, [zones[0].name, zones[0].name, zones[0].name, zones[1].name, zones[2].name])
    XCTAssertEqual(outcomes.withLock { $0 }, [zones[0].name: false, zones[1].name: true, zones[2].name: true])
  }

  func testAccountChangePreventsEveryCleanupWriteAndPreservesOperationAndCleanupFailure() async {
    for changeAfterWrite in [false, true] {
      let calls = Mutex(0)
      let reads = Mutex(0)
      let changed = Mutex(!changeAfterWrite)
      let zones = ["first", "later"].map { CloudZoneID(name: "snipsnap-contract-account-change-\($0)", ownerName: "owner") }
      do {
        try await CloudDevelopmentTransportContract.runWithCleanup(operation: { throw ProbeFailure.operation }, cleanup: {
          try await CloudDevelopmentTransportContract.cleanupZones(zones, validateAccount: {
            if changed.withLock({ $0 }) { throw CloudDevelopmentTransportContract.ContractError.accountChanged }
          }, delete: { _ in
            calls.withLock { $0 += 1 }
            changed.withLock { $0 = true }
          }, exists: { _ in reads.withLock { $0 += 1 }; return true })
        })
        XCTFail("Both errors must remain visible")
      } catch {
        let detail = (error as? CloudDevelopmentTransportContract.StepFailure)?.detail ?? ""
        XCTAssertTrue(detail.contains(ProbeFailure.operation.localizedDescription))
        XCTAssertTrue(detail.contains("accountChanged"))
        XCTAssertTrue(zones.allSatisfy { detail.contains($0.name) })
      }
      XCTAssertEqual(calls.withLock { $0 }, changeAfterWrite ? 1 : 0)
      XCTAssertEqual(reads.withLock { $0 }, 0, "Do not inspect the new account to verify old-account cleanup")
    }
  }

  func testBudgetReservesCleanupAndWillNotStartWorkPastDeadline() async throws {
    let now = Date(timeIntervalSince1970: 100)
    let budget = CloudDevelopmentContractBudget(workDeadline: now, cleanupDeadline: now.addingTimeInterval(600), now: { now })
    XCTAssertThrowsError(try budget.check("work"))
    XCTAssertNoThrow(try budget.check("cleanup", cleanup: true))
    let started = Mutex(false)
    do { _ = try await budget.perform("expired") { started.withLock { $0 = true } }; XCTFail("Expired work started") }
    catch { XCTAssertEqual(error as? CloudDevelopmentContractFailure, .deadline("expired")) }
    XCTAssertFalse(started.withLock { $0 })
  }

  func testCombinedFailurePreservesOriginalOracleAndExactZoneRetryCause() async {
    let zone = CloudZoneID(name: "snipsnap-contract-denied-cleanup", ownerName: "owner")
    do {
      try await CloudDevelopmentTransportContract.runWithCleanup(operation: {
        throw CloudDevelopmentContractFailure.oracle("literal-original-failure")
      }, cleanup: {
        try await CloudDevelopmentTransportContract.cleanupZones([zone], validateAccount: {},
          delete: { _ in throw CKError(.permissionFailure) }, exists: { _ in true })
      })
      XCTFail("The failed operation and denied cleanup cannot become success")
    } catch {
      let detail = (error as? CloudDevelopmentTransportContract.StepFailure)?.detail ?? ""
      XCTAssertTrue(detail.contains("literal-original-failure"))
      XCTAssertTrue(detail.contains(zone.name))
      XCTAssertTrue(detail.contains("CKError(\(CKError.Code.permissionFailure.rawValue))"))
      XCTAssertTrue(detail.contains("zoneCleanupWasNotConfirmed"))
    }
  }

  func testPublicThreeAndFiveAttachmentReordersSupplyEveryCompanionInOneLogicalAtomicBatch() async throws {
    for count in [3, 5] {
      let f = try ObserverFixture()
      defer { try? FileManager.default.removeItem(at: f.root) }
      let data = CloudKitRecordMapper.id(for: f.id).zone
      let payload = CloudZoneID(name: "snipsnap-contract-planner-payload", ownerName: "owner")
      let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "test", generation: UUID(), zones: [data, payload])
      let library = try SwiftDataSnipLibrary(storeURL: f.root.appendingPathComponent("library/store"))
      let names = Array(["A.txt", "B.txt", "C.txt", "D.txt", "E.txt"].prefix(count))
      let urls = try names.map { name in
        let url = f.root.appendingPathComponent(name)
        try Data("original bytes for \(name)".utf8).write(to: url); return url
      }
      let added = try await library.perform(.add(content: "planner", origin: .quickEntry, source: nil,
        listID: SnipList.inbox.id, attachmentURLs: urls, requestID: UUID(), now: .distantPast), sortedBy: .manual)
      guard case .add(.added(let snipID)) = added.outcome else { return XCTFail("Missing public add result") }
      let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: data, payloadZone: payload)
      try await store.approveEnrollment(references: [.init(kind: .list, domainID: SnipList.inbox.id), .init(kind: .snip, domainID: snipID)])
      let fake = StrictContractTransport(server: FakeCloudServer(), namespace: namespace, data: data)
      let coordinator = CloudFullSyncCoordinator(store: store, transport: fake, fetchScope: .zones([data]))
      try await ContractPlannerTestDriver.bootstrap(coordinator, transport: fake, zones: [data, payload], validate: {})
      let quiet = try await store.pendingChanges()
      guard quiet.operations.isEmpty else { return XCTFail("Planner bootstrap requires created and confirmed zones") }
      let before = try await library.checkedSnapshot(sortedBy: .manual)
      let snip = try XCTUnwrap(before.snips.first { $0.id == snipID })
      XCTAssertEqual(snip.attachments.map(\.fileName), names)
      let byName = Dictionary(uniqueKeysWithValues: snip.attachments.map { ($0.fileName, $0.id) })
      let desired = Array(["B.txt", "A.txt", "C.txt", "D.txt", "E.txt"].prefix(count))
      _ = try await library.perform(.editAttachments(snipID: snipID, content: snip.content,
        edits: try desired.map { .existing(attachmentID: try XCTUnwrap(byName[$0])) },
        expectedUpdatedAt: snip.updatedAt, now: Date(timeIntervalSince1970: 2)), sortedBy: .manual)
      let plan = try await store.pendingChanges()
      XCTAssertEqual(plan.operations.count, count)
      let metadata = plan.operations.compactMap { op -> CloudRecordDraft? in if case .save(let draft) = op { draft } else { nil } }
      XCTAssertEqual(metadata.count, count)
      let expectedPositions = ["A.txt": 1, "B.txt": 0, "C.txt": 2, "D.txt": 3, "E.txt": 4]
      for draft in metadata {
        XCTAssertEqual(draft.recordType, "AttachmentMetadata")
        XCTAssertNotNil(draft.base, "Bootstrap acknowledgement is the order base")
        guard case .string(let name) = draft.encryptedFields["fileName"] else { return XCTFail("Missing original name") }
        let position = try XCTUnwrap(expectedPositions[name])
        XCTAssertEqual(draft.encryptedFields["position"], .int64(Int64(position)))
      }
      try await f.transport.start(state: nil)
      let observer = try f.observer()
      try await f.confirmInitialFetchEvents()
      try await f.transport.scheduleAutomaticSync(plan)
      await observer.forward(.willSendChanges)
      let supplied = await observer.batch(scope: .all)
      let batch = try XCTUnwrap(supplied)
      XCTAssertTrue(batch.atomicByZone)
      XCTAssertEqual(batch.recordsToSave.count, count)
      XCTAssertEqual(Set(batch.recordsToSave.map { CloudKitRecordMapper.id(for: $0.recordID) }), Set(metadata.map(\.id)))
      let extra = await observer.batch(scope: .all)
      XCTAssertNil(extra, "The unchanged companions must belong to the single supplied group")
      await f.transport.reset()
    }
  }

  func testPerCaseDeadlineCancelsCooperativeWork() async {
    let budget = CloudDevelopmentContractBudget(workDeadline: .distantFuture, cleanupDeadline: .distantFuture)
    do {
      _ = try await budget.perform("case", seconds: 0) { try await Task.sleep(for: .seconds(60)) }
      XCTFail("A cooperative stalled case must time out")
    } catch { XCTAssertEqual(error as? CloudDevelopmentContractFailure, .deadline("case")) }
  }

  func testPrewriteManifestIsDurableAndTraceRedactsForeignAccountAndZoneContext() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let evidence = try CloudDevelopmentContractEvidence(directory: root, zoneNames: ["snipsnap-contract-only"])
    let manifest = CloudDevelopmentContractManifest(runID: UUID(), sourceRevision: String(repeating: "a", count: 40),
      harnessRevision: String(repeating: "b", count: 40), accountFingerprint: CloudDevelopmentContractEvidence.fingerprint("private-account"),
      startedAt: .distantPast, workDeadline: .distantFuture, cleanupDeadline: .distantFuture, zones: ["snipsnap-contract-only"])
    try evidence.write(manifest, named: "manifest.json")
    let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
    XCTAssertNotNil(decoded["accountFingerprint"])
    evidence.append(client: "test", kind: "foreign", ids: [CKRecord.ID(recordName: "private-record",
      zoneID: CKRecordZone.ID(zoneName: "app-zone", ownerName: "private-account"))])
    try evidence.flush()
    let text = try String(contentsOf: root.appendingPathComponent("sdk-trace.json"), encoding: .utf8)
    XCTAssertTrue(text.contains("<foreign-zone>"))
    XCTAssertFalse(text.contains("private-account") || text.contains("private-record") || text.contains("app-zone"))
    XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("manifest.json"), encoding: .utf8).contains("private-account"))
    XCTAssertThrowsError(try evidence.write(manifest, named: "../escape.json"))
    XCTAssertThrowsError(try CloudDevelopmentContractEvidence(directory: root, zoneNames: ["app-zone"]))
  }

  private func entry(_ kind: String, ids: [String], errors: [String: Int] = [:], tags: [String: String] = [:]) -> CloudDevelopmentContractEvidence.Entry {
    .init(sequence: 0, phase: "test", client: "test", kind: kind, ids: ids, atomic: true, errors: errors, serverTags: tags, pending: [])
  }
}

private enum ProbeFailure: Error { case operation, delete }

private final class ObserverFixture {
  let root: URL
  let evidence: CloudDevelopmentContractEvidence
  let base = ProofEngine()
  let cell = ObserverSlot()
  let transport: CloudKitRecordTransport
  let id: CKRecord.ID
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let zone = CloudZoneID(name: "snipsnap-contract-observer", ownerName: "owner")
    id = CKRecord.ID(recordName: "literal", zoneID: CloudKitRecordMapper.zoneID(for: zone))
    evidence = try CloudDevelopmentContractEvidence(directory: root, zoneNames: [zone.name])
    let evidence = evidence, base = base, cell = cell
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "test", generation: UUID(), zones: [zone])
    transport = CloudKitRecordTransport(namespace: namespace, automaticallyFetchedZones: nil,
      diagnostics: AppDiagnosticRecorder(record: { _ in }), readRecords: { _, _ in [:] }, makeEngine: { _, _, transport in
        let observer = CloudDevelopmentEngineObserver(transport: transport, evidence: evidence, client: "proxy") { _ in base }
        cell.value.withLock { $0 = observer }; return observer
      })
  }
  func observer() throws -> CloudDevelopmentEngineObserver { try XCTUnwrap(cell.value.withLock { $0 }) }

  func confirmInitialFetchEvents() async throws {
    let observer = try observer()
    await observer.forward(.willFetchChanges)
    await observer.forward(.didFetchRecordZoneChanges(zoneID: id.zoneID, error: nil))
    await observer.forward(.didFetchChanges)
    let head = await transport.contractHeadEvent()
    let event = try XCTUnwrap(head, "The scripted initial fetch must be queued before acknowledgement")
    guard case .batch(let pending) = event, case .fetched(let batch) = pending.batch else {
      XCTFail("Expected the initial fetched batch, not an empty queue or another checkpoint")
      throw ProbeFailure.operation
    }
    XCTAssertTrue(batch.isInitialFetch)
    XCTAssertTrue(batch.items.isEmpty)
    XCTAssertEqual(batch.zoneEvents, [.fetched(CloudKitRecordMapper.id(for: id.zoneID))])
    try await transport.confirmApplied(event.id)
    let remaining = await transport.contractHeadEvent()
    XCTAssertNil(remaining, "Acknowledge the initial fetched batch before beginning a send")
  }
}

private extension CloudKitRecordTransport {
  /// Resolve the actor implementation; an async concrete call can choose the protocol's nil default.
  func contractHeadEvent() -> CloudRecordTransportEvent? { pendingEvent() }
}

private final class ObserverSlot: Sendable {
  let value = Mutex<CloudDevelopmentEngineObserver?>(nil)
}

private final class ProofEngine: CloudKitRecordEngine, Sendable {
  struct State: Sendable {
    var pending: [CKSyncEngine.PendingRecordZoneChange] = []
    var zones: [CKSyncEngine.PendingDatabaseChange] = []
    var fetches: [CKSyncEngine.FetchChangesOptions] = []
    var sends: [CKSyncEngine.SendChangesOptions] = []
    var failFetch = false
  }
  let state = Mutex(State())
  let failure = NSError(domain: "observer-negative-control", code: 123)
  var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { state.withLock { $0.pending } }
  var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] { state.withLock { $0.zones } }
  func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) { state.withLock { $0.pending += changes } }
  func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) { state.withLock { $0.pending.removeAll { changes.contains($0) } } }
  func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) { state.withLock { $0.zones += changes } }
  func remove(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) { state.withLock { $0.zones.removeAll { changes.contains($0) } } }
  func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws {
    let fail = state.withLock { $0.fetches.append(options); return $0.failFetch }
    if fail { throw failure }
  }
  func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws {
    state.withLock { $0.sends.append(options) }; throw failure
  }
}

#endif
