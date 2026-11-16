#if DEBUG
import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence
import Synchronization
import XCTest
@_spi(Maintainer) @testable import SnipSnapCloud

final class CloudDevelopmentHarnessWave1Tests: XCTestCase {
  func testStrictZoneOracleRequiresPhysicalCreationAndConfirmation() async throws {
    let f = try Wave1PlannerFixture()
    defer { f.remove() }
    try await f.transport.start(state: nil)
    let missing = try await f.transport.fetch(scope: .all)
    XCTAssertEqual(missing.zoneEvents, [.failed(f.data, .zoneMissing)])
    try await f.transport.confirmApplied(missing.id)
    let created = try await f.transport.send(.init(operations: [], zonesToSave: f.zones))
    let physical = await f.server.hasZone(f.data)
    XCTAssertTrue(physical)
    do {
      _ = try await f.transport.fetch(scope: .all)
      XCTFail("The real receipt gate must reject fetch before creation confirmation")
    } catch { XCTAssertEqual(error as? FakeCloudError, .wrongBatchConfirmation) }
    try await f.transport.confirmApplied(created.id)
    let ready = try await f.transport.fetch(scope: .all)
    XCTAssertEqual(ready.zoneEvents, [.fetched(f.data)])
    try await f.transport.confirmApplied(ready.id)
  }

  func testPlannerRejectsAccountNoticeAfterAdmission() async throws {
    let f = try Wave1PlannerFixture()
    defer { f.remove() }
    try await f.createZones()
    await f.transport.injectAccountNoticeOnFetch(changed: true)
    try f.account.validate() // Phase admission succeeds before the notice arrives.
    var stopped = false
    do { try await f.bootstrap() }
    catch CloudDevelopmentTransportContract.ContractError.accountChanged { stopped = true }
    XCTAssertTrue(stopped, "A later account change must stop the admitted planner")
    let state = await f.transport.observations()
    XCTAssertFalse(state.noticeConfirmed)
    XCTAssertEqual(state.sendsAfterChange, 0)
    let head = await f.transport.pendingEvent()
    XCTAssertEqual(head?.id, state.noticeID)
  }

  func testPlannerRevalidatesBeforeLaterSend() async throws {
    let f = try Wave1PlannerFixture()
    defer { f.remove() }
    try await f.createZones()
    await f.transport.changeAccountAfterFetchConfirmation()
    try f.account.validate()
    var stopped = false
    do { try await f.bootstrap() }
    catch CloudDevelopmentTransportContract.ContractError.accountChanged { stopped = true }
    XCTAssertTrue(stopped, "Account validation must also protect later sends")
    let state = await f.transport.observations()
    XCTAssertEqual(state.sendsAfterChange, 0)
  }

  func testPlannerAcceptsSameAccountNotice() async throws {
    let f = try Wave1PlannerFixture()
    defer { f.remove() }
    try await f.createZones()
    await f.transport.injectAccountNoticeOnFetch(changed: false)
    try await f.bootstrap()
    let state = await f.transport.observations()
    XCTAssertTrue(state.noticeConfirmed)
    let pending = try await f.store.pendingChanges()
    XCTAssertTrue(pending.operations.isEmpty)
  }

  func testRecoveredDeleteFailureSurvivesDurableCleanupEncoding() async throws {
    try await recoveredCleanup(failingOperation: "delete", code: .networkUnavailable)
  }

  func testRecoveredReadFailureSurvivesDurableCleanupEncoding() async throws {
    try await recoveredCleanup(failingOperation: "read", code: .serviceUnavailable)
  }

  func testUnresolvedCleanupSurvivesDurableFailureEncoding() async throws {
    let root = scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let zone = CloudZoneID(name: "snipsnap-contract-unresolved", ownerName: "owner")
    let evidence = try CloudDevelopmentContractEvidence(directory: root, zoneNames: [zone.name])
    do {
      _ = try await CloudDevelopmentTransportContract.cleanupZones([zone], validateAccount: {},
        delete: { _ in throw CKError(.permissionFailure) }, exists: { _ in true })
      XCTFail("Cleanup cannot succeed while the zone is still present")
    } catch {
      guard let value = error as? any Encodable else {
        return XCTFail("Unresolved cleanup must retain a durable structured outcome")
      }
      try evidence.write(value, named: "cleanup-failure.json")
      let json = try object(root.appendingPathComponent("cleanup-failure.json"))
      let outcomes = try XCTUnwrap(json["outcomes"] as? [[String: Any]])
      let outcome = try XCTUnwrap(outcomes.first)
      XCTAssertEqual(outcome["zoneName"] as? String, zone.name)
      XCTAssertEqual(outcome["verifiedAbsent"] as? Bool, false)
      let attempts = try XCTUnwrap(outcome["attempts"] as? [[String: Any]])
      XCTAssertEqual(attempts.count, 6)
      XCTAssertEqual(attempts.compactMap { $0["number"] as? Int }, [1, 1, 2, 2, 3, 3])
      XCTAssertEqual(attempts.filter { ($0["operation"] as? String) == "delete" }.compactMap { $0["result"] as? String },
        Array(repeating: "CKError(\(CKError.Code.permissionFailure.rawValue))", count: 3))
    }
  }

  func testBaselineWrappedContractAndCleanupCausesSurviveSanitization() async throws {
    let zone = CloudZoneID(name: "snipsnap-contract-wrapped", ownerName: "owner")
    do {
      try await CloudDevelopmentTransportContract.runWithCleanup(operation: {
        do {
          try await CloudDevelopmentTransportContract.exercise(transport: BaselineFault(.creation),
            reader: BaselineFault(.creation), name: "fake", zone: zone, drafts: [])
        } catch {
          let beforeCleanup = CloudDevelopmentAtomicContract.safe(error)
          XCTAssertTrue(beforeCleanup.contains("zoneWasNotCreated"), "The actual baseline wrapper must survive the top-level sanitizer")
          throw error
        }
      }, cleanup: { throw CloudDevelopmentContractFailure.oracle("literal-original-failure") })
      XCTFail("Both baseline operation and cleanup must fail")
    } catch {
      let safe = CloudDevelopmentAtomicContract.safe(error)
      XCTAssertTrue(safe.contains("create zone"))
      XCTAssertTrue(safe.contains("zoneWasNotCreated"))
      XCTAssertTrue(safe.contains("literal-original-failure"))
    }
  }

  func testBaselineCloudCodeSurvivesWithoutSensitiveDetails() async throws {
    let zone = CloudZoneID(name: "snipsnap-contract-cloud-code", ownerName: "owner")
    do {
      try await CloudDevelopmentTransportContract.exercise(transport: BaselineFault(.cloud),
        reader: BaselineFault(.cloud), name: "fake", zone: zone, drafts: [])
      XCTFail("The scripted SDK error must escape the baseline")
    } catch {
      let safe = CloudDevelopmentAtomicContract.safe(error)
      XCTAssertTrue(safe.contains("start"))
      XCTAssertTrue(safe.contains("CKError(\(CKError.Code.networkUnavailable.rawValue))"))
      XCTAssertFalse(safe.contains("PRIVATE_ACCOUNT") || safe.contains("PRIVATE_TOKEN") || safe.contains("/private/body"))
    }
  }

  func testForgedStepDetailCannotReachHostOrManifest() throws {
    let root = scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let evidence = try CloudDevelopmentContractEvidence(directory: root, zoneNames: ["snipsnap-contract-redaction"])
    for stage in ["atomic-contract", "operation and cleanup failed", "Development contract"] {
      let error = CloudDevelopmentTransportContract.StepFailure(stage: stage,
        detail: "PRIVATE_TOKEN /private/body PRIVATE_ACCOUNT")
      let safe = CloudDevelopmentAtomicContract.safe(error)
      try evidence.write(["failure": safe], named: "failure.json")
      let text = try String(contentsOf: root.appendingPathComponent("failure.json"), encoding: .utf8)
      XCTAssertFalse(text.contains("PRIVATE_TOKEN") || text.contains("/private/body") || text.contains("PRIVATE_ACCOUNT"))
    }
  }

#if os(macOS)
  func testPolicyChecksDoNotDependOnDirtyCallerCheckout() throws {
    let root = scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let scripts = root.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    for name in ["cloud-dev-transport-contract.sh", "cloud-dev-transport-contract-tests.sh", "cloud-dev-transport-contract-evidence.rb"] {
      try FileManager.default.copyItem(at: repository.appendingPathComponent("scripts/\(name)"), to: scripts.appendingPathComponent(name))
    }
    let git = URL(fileURLWithPath: "/usr/bin/git")
    for args in [["init", "-q"], ["add", "."], ["-c", "user.name=Contract Test", "-c", "user.email=contract@example.invalid",
      "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"]] {
      XCTAssertEqual(try process(git, args, directory: root).status, 0)
    }
    let validator = scripts.appendingPathComponent("cloud-dev-transport-contract-evidence.rb")
    var dirtySource = try Data(contentsOf: validator)
    dirtySource.append(Data("\n# tracked edit\n".utf8))
    try dirtySource.write(to: validator, options: .atomic)
    try Data("untracked\n".utf8).write(to: root.appendingPathComponent("untracked.txt"))
    let before = try process(git, ["status", "--porcelain"], directory: root).output
    let result = try process(scripts.appendingPathComponent("cloud-dev-transport-contract-tests.sh"), [], directory: root)
    XCTAssertEqual(result.status, 0, "Policy checks must isolate their live source guards: \(result.output)")
    XCTAssertEqual(try process(git, ["status", "--porcelain"], directory: root).output, before)
  }
#endif

  private func recoveredCleanup(failingOperation: String, code: CKError.Code) async throws {
    let root = scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let zone = CloudZoneID(name: "snipsnap-contract-recovered", ownerName: "owner")
    let evidence = try CloudDevelopmentContractEvidence(directory: root, zoneNames: [zone.name])
    let deletes = Mutex(0), reads = Mutex(0)
    // Type-erased existing return seam: d89 returns Void, so this compiles without a future type.
    let returned: Any = try await CloudDevelopmentTransportContract.cleanupZones([zone], validateAccount: {}, delete: { _ in
      let n = deletes.withLock { $0 += 1; return $0 }
      if failingOperation == "delete" && n == 1 { throw CKError(code) }
    }, exists: { _ in
      let n = reads.withLock { $0 += 1; return $0 }
      if failingOperation == "read" && n == 1 { throw CKError(code) }
      return failingOperation == "delete" && n == 1
    })
    guard let value = returned as? any Encodable else {
      return XCTFail("Recovered cleanup must return durable absence AND attempt evidence")
    }
    try evidence.write(value, named: "cleanup-success.json")
    let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("cleanup-success.json"))) as? [[String: Any]])
    let outcome = try XCTUnwrap(decoded.first)
    XCTAssertEqual(outcome["zoneName"] as? String, zone.name)
    XCTAssertEqual(outcome["verifiedAbsent"] as? Bool, true)
    let attempts = try XCTUnwrap(outcome["attempts"] as? [[String: Any]])
    XCTAssertEqual(attempts.count, 4)
    XCTAssertEqual(attempts.compactMap { $0["operation"] as? String }, ["delete", "read", "delete", "read"])
    XCTAssertEqual(attempts.compactMap { $0["number"] as? Int }, [1, 1, 2, 2])
    XCTAssertTrue(attempts.contains { ($0["operation"] as? String) == failingOperation && ($0["result"] as? String) == "CKError(\(code.rawValue))" })
    XCTAssertEqual(attempts.last?["result"] as? String, "absent")
  }

  private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("wave1-\(UUID().uuidString)") }
  private func object(_ url: URL) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }
#if os(macOS)
  private func process(_ executable: URL, _ arguments: [String], directory: URL) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
    process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    let log = directory.deletingLastPathComponent().appendingPathComponent("wave1-output-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: log) }
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }
    process.standardOutput = handle; process.standardError = handle
    try process.run(); process.waitUntilExit()
    return (process.terminationStatus, try String(contentsOf: log, encoding: .utf8))
  }
#endif
}

// The pre-repair bootstrap used by the existing account-free 3/5 planner fixture.
// The fix binds both live and account-free callers to one DEBUG implementation.
enum ContractPlannerTestDriver {
  static func bootstrap(_ coordinator: CloudFullSyncCoordinator, transport: any CloudRecordTransport,
    zones: Set<CloudZoneID>, validate: @escaping @Sendable () async throws -> Void) async throws {
    try await validate()
    _ = try await coordinator.sync()
    _ = try await coordinator.sendPendingUntilSettled()
  }
}

final class Wave1Account: Sendable {
  let changed = Mutex(false)
  func validate() throws {
    if changed.withLock({ $0 }) { throw CloudDevelopmentTransportContract.ContractError.accountChanged }
  }
}

struct Wave1PlannerFixture: Sendable {
  let root: URL
  let data = CloudZoneID(name: "snipsnap-contract-planner-data", ownerName: "owner")
  let payload = CloudZoneID(name: "snipsnap-contract-planner-payload", ownerName: "owner")
  let account = Wave1Account()
  let server: FakeCloudServer
  let transport: StrictContractTransport
  let store: CloudFullSyncPersistence
  let coordinator: CloudFullSyncCoordinator
  var zones: Set<CloudZoneID> { [data, payload] }
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("wave1-planner-\(UUID().uuidString)")
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "test", generation: UUID(), zones: [data, payload])
    server = FakeCloudServer()
    transport = StrictContractTransport(server: server, namespace: namespace, data: data, account: account)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: data, payloadZone: payload)
    coordinator = CloudFullSyncCoordinator(store: store, transport: transport, fetchScope: .zones([data]))
  }
  func bootstrap() async throws {
    // A real pending core draft is enough to detect a later send under the changed account.
    try await store.approveEnrollment(references: [.init(kind: .list, domainID: SnipList.inbox.id)])
    try await ContractPlannerTestDriver.bootstrap(coordinator, transport: transport, zones: zones, validate: { try account.validate() })
  }
  func createZones() async throws {
    try await transport.start(state: nil)
    let created = try await transport.send(.init(operations: [], zonesToSave: zones))
    try await transport.confirmApplied(created.id)
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

actor StrictContractTransport: CloudRecordTransport {
  let server: FakeCloudServer
  let base: FakeCloudRecordTransport
  let data: CloudZoneID
  let account: Wave1Account
  var confirmedZones: Set<CloudZoneID> = []
  var creations: [UUID: Set<CloudZoneID>] = [:]
  var notice: CloudRecordTransportEvent?
  var noticeID: UUID?
  var noticeConfirmed = false
  var sendsAfterChange = 0
  var onFetch: Bool?
  var changeAfterFetch = false
  var fetchedID: UUID?
  init(server: FakeCloudServer, namespace: CloudSyncNamespace, data: CloudZoneID, account: Wave1Account = Wave1Account()) {
    self.server = server; self.data = data; self.account = account
    base = FakeCloudRecordTransport(server: server, namespace: namespace, automaticallyFetchedZones: [data])
  }
  func injectAccountNoticeOnFetch(changed: Bool) { onFetch = changed }
  func changeAccountAfterFetchConfirmation() { changeAfterFetch = true }
  func observations() -> (noticeConfirmed: Bool, noticeID: UUID?, sendsAfterChange: Int) { (noticeConfirmed, noticeID, sendsAfterChange) }
  func start(state: CloudEngineStateEnvelope?) async throws { try await base.start(state: state) }
  func reset() async { await base.reset() }
  func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch {
    let adapter: any CloudRecordTransport = base
    if await adapter.pendingEvent() != nil { return try await base.fetch(scope: scope) }
    let exists = await server.hasZone(data)
    if !confirmedZones.contains(data) || !exists { await base.failNextFetchedZone(data, failure: .zoneMissing) }
    let fetched = try await base.fetch(scope: scope)
    fetchedID = fetched.id
    if let changed = onFetch {
      onFetch = nil; account.changed.withLock { $0 = changed }
      let id = UUID(); noticeID = id; notice = .accountChange(id)
    }
    return fetched
  }
  func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
    if account.changed.withLock({ $0 }) { sendsAfterChange += 1 }
    let sent = try await base.send(batch)
    creations[sent.id] = batch.zonesToSave
    return sent
  }
  func pendingEvent() async -> CloudRecordTransportEvent? {
    if let notice { return notice }
    let base: any CloudRecordTransport = base
    return await base.pendingEvent()
  }
  func confirmApplied(_ id: UUID) async throws {
    if id == noticeID && notice != nil { notice = nil; noticeConfirmed = true; return }
    try await base.confirmApplied(id)
    confirmedZones.formUnion(creations.removeValue(forKey: id) ?? [])
    if id == fetchedID && changeAfterFetch { account.changed.withLock { $0 = true }; changeAfterFetch = false }
  }
  func confirmApplied(_ id: UUID, outboundAdmission: CloudRecordOutboundAdmission) async throws { try await confirmApplied(id) }
  func fetchRecord(_ id: CloudRecordID, fields: Set<String>) async throws -> CloudRecordSnapshot? { try await base.fetchRecord(id, fields: fields) }
  func fetchAsset(_ id: CloudRecordID, field: String, destination: CloudAssetDestination) async throws -> CloudAssetReceipt? {
    try await base.fetchAsset(id, field: field, destination: destination)
  }
}

private struct BaselineFault: CloudRecordTransport {
  enum Mode: Sendable { case creation, cloud }
  let mode: Mode
  init(_ mode: Mode) { self.mode = mode }
  func start(state: CloudEngineStateEnvelope?) async throws {
    if case .cloud = mode {
      throw CKError(_nsError: NSError(domain: CKErrorDomain, code: CKError.Code.networkUnavailable.rawValue,
        userInfo: [NSLocalizedDescriptionKey: "PRIVATE_TOKEN /private/body", "account": "PRIVATE_ACCOUNT"]))
    }
  }
  func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch { .init(id: UUID(), items: [], engineState: nil) }
  func confirmApplied(_ id: UUID) async throws {}
  func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch { throw CloudDevelopmentContractFailure.oracle("unexpected-test-fetch") }
  func fetchRecord(_ id: CloudRecordID, fields: Set<String>) async throws -> CloudRecordSnapshot? { nil }
  func fetchAsset(_ id: CloudRecordID, field: String, destination: CloudAssetDestination) async throws -> CloudAssetReceipt? { nil }
}
#endif
