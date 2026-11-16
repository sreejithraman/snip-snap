#if DEBUG
import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence
import Synchronization
import XCTest
@_spi(Maintainer) @testable import SnipSnapCloud

final class CloudDevelopmentHarnessWave1Tests: XCTestCase {
  func testBaselineRejectsStaleManifestAccountBeforeStartingEitherEngine() async throws {
    let f = try BaselineAdmissionFixture()
    defer { f.remove() }
    try f.account.validate() // Phase admission, before the intervening fake baseline.
    f.account.changed.withLock { $0 = true }
    let failure = await f.failure(drafts: [])
    XCTAssertEqual(failure, "CloudKit: start: contract:accountChanged")
    let writer = await f.writer.observation(), reader = await f.reader.observation()
    XCTAssertFalse(writer.started || reader.started)
    XCTAssertEqual(writer.writes, [])
    let exists = await f.server.hasZone(f.zone)
    XCTAssertFalse(exists)
  }

  func testBaselineRejectsAccountChangeDuringEitherStartBeforeZoneCreation() async throws {
    for readerChanges in [false, true] {
      let f = try BaselineAdmissionFixture(writerTrigger: readerChanges ? .none : .start,
        readerTrigger: readerChanges ? .start : .none)
      defer { f.remove() }
      try f.account.validate()
      let failure = await f.failure(drafts: [])
      XCTAssertTrue(f.account.changed.withLock { $0 }, "The awaited start must actually change the account")
      XCTAssertEqual(failure, "CloudKit: create zone: contract:accountChanged")
      let writer = await f.writer.observation()
      XCTAssertEqual(writer.writes, [])
      let exists = await f.server.hasZone(f.zone)
      XCTAssertFalse(exists)
    }
  }

  func testBaselineRejectsAccountChangeAfterInitialFetchBeforeTextOrPayloadSave() async throws {
    for payload in [false, true] {
      let f = try BaselineAdmissionFixture(writerTrigger: .initialFetchConfirmed)
      defer { f.remove() }
      let draft = payload ? f.payload : f.text
      let failure = await f.failure(drafts: [draft])
      let writer = await f.writer.observation()
      XCTAssertTrue(writer.initialFetchConfirmed)
      XCTAssertTrue(f.account.changed.withLock { $0 })
      XCTAssertEqual(failure, payload ? "CloudKit / AttachmentPayload: save record: contract:accountChanged"
        : "CloudKit / Snip: save record: contract:accountChanged")
      XCTAssertEqual(writer.writes, [.zone(f.zone)])
      let remaining = await f.server.fullSnapshot(for: draft.id)
      XCTAssertNil(remaining)
    }
  }

  func testBaselineRejectsAccountChangeAfterContentReadBeforeTextOrPayloadDelete() async throws {
    for payload in [false, true] {
      let f = try BaselineAdmissionFixture(readerTrigger: .contentRead)
      defer { f.remove() }
      let draft = payload ? f.payload : f.text
      let failure = await f.failure(drafts: [draft])
      let writer = await f.writer.observation(), reader = await f.reader.observation()
      XCTAssertTrue(f.account.changed.withLock { $0 })
      XCTAssertEqual(reader.records.map(\.id), [draft.id])
      if payload {
        XCTAssertEqual(reader.assets, [Data([0, 1, 255, 128, 42])])
      } else {
        XCTAssertEqual(reader.records.first?.encryptedFields, ["text": .string("Keep the manifest account")])
      }
      XCTAssertEqual(failure, payload ? "CloudKit / AttachmentPayload: delete record: contract:accountChanged"
        : "CloudKit / Snip: delete record: contract:accountChanged")
      XCTAssertEqual(writer.writes, [.zone(f.zone), .save(draft.id)])
      let remaining = await f.server.fullSnapshot(for: draft.id)
      XCTAssertEqual(remaining?.id, draft.id, "Account mismatch must leave the original record intact")
      if let remaining {
        XCTAssertEqual(remaining.recordType, payload ? "AttachmentPayload" : "Snip")
        XCTAssertEqual(remaining.schemaVersion, 1)
        XCTAssertEqual(remaining.encryptedFields, payload ? [:] : ["text": .string("Keep the manifest account")])
        XCTAssertEqual(remaining.assetFields, payload ? ["payload"] : [])
      }
    }
  }

  func testBaselineSameAccountStillTransfersLiteralTextPayloadBytesAndDeletions() async throws {
    let f = try BaselineAdmissionFixture()
    defer { f.remove() }
    try await f.exercise(drafts: [f.text, f.payload])
    let writer = await f.writer.observation(), reader = await f.reader.observation()
    XCTAssertTrue(writer.started && reader.started && writer.initialFetchConfirmed)
    XCTAssertFalse(f.account.changed.withLock { $0 })
    XCTAssertEqual(writer.writes, [.zone(f.zone), .save(f.text.id), .delete(f.text.id),
      .save(f.payload.id), .delete(f.payload.id)])
    XCTAssertEqual(reader.records.map(\.id), [f.text.id, f.payload.id])
    XCTAssertEqual(reader.records.map(\.recordType), ["Snip", "AttachmentPayload"])
    XCTAssertEqual(reader.records.first?.encryptedFields, ["text": .string("Keep the manifest account")])
    XCTAssertEqual(reader.records.first?.routingFields["snipID"], .string("00000000-0000-0000-0000-000000000061"))
    XCTAssertEqual(reader.records.last?.assetFields, ["payload"])
    XCTAssertEqual(reader.assets, [Data([0, 1, 255, 128, 42])])
    for id in [f.text.id, f.payload.id] {
      let remaining = await f.server.fullSnapshot(for: id)
      XCTAssertNil(remaining)
    }
  }

  func testStrictZoneOracleRequiresPhysicalCreationAndConfirmation() async throws {
    let f = try Wave1PlannerFixture()
    defer { f.remove() }
    try await f.transport.start(state: nil)
    let missing = try await f.transport.fetch(scope: .all)
    XCTAssertEqual(missing.zoneEvents, [.failed(f.data, .zoneMissing)])
    try await f.transport.confirmApplied(missing.id)
    let created = try await f.transport.send(.init(operations: [], zonesToSave: f.zones))
    let physical = await f.server.hasZone(f.data)
    let payloadExists = await f.server.hasZone(f.payload)
    XCTAssertTrue(physical)
    XCTAssertTrue(payloadExists)
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


  func testCancellationHasFixedSafeAndOutwardCause() {
    XCTAssertEqual(CloudDevelopmentAtomicContract.safe(CancellationError()), "cancelled")
    let outward = CloudDevelopmentTransportContract.StepFailure(stage: "atomic-contract", error: CancellationError())
    XCTAssertEqual(outward.localizedDescription, "atomic-contract: cancelled")
    let unknown = NSError(domain: "PRIVATE_ACCOUNT", code: 7,
      userInfo: [NSLocalizedDescriptionKey: "PRIVATE_TOKEN /private/body"])
    XCTAssertEqual(CloudDevelopmentAtomicContract.safe(unknown), "redacted-error")
    XCTAssertEqual(CloudDevelopmentTransportContract.StepFailure(stage: "atomic-contract", error: unknown).localizedDescription,
      "atomic-contract: redacted-error")
  }

  func testBaselineWrappedCancellationSurvivesDurablePhaseAndHostRendering() async throws {
    let root = scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let zone = CloudZoneID(name: "snipsnap-contract-cancelled-baseline", ownerName: "owner")
    let evidence = try CloudDevelopmentContractEvidence(directory: root, zoneNames: [zone.name])
    do {
      try await cancelledBaseline(zone: zone)
      XCTFail("The baseline must propagate its cancellation input")
    } catch {
      let safe = CloudDevelopmentAtomicContract.safe(error)
      XCTAssertEqual(safe, "fake: start: cancelled")
      XCTAssertEqual(error.localizedDescription, "fake: start: cancelled")
      let phase = CloudDevelopmentTransportContract.StepFailure(stage: "atomic-contract", error: error)
      let host = CloudDevelopmentTransportContract.StepFailure(stage: "Development contract", error: phase)
      XCTAssertEqual(host.localizedDescription, "Development contract: atomic-contract: fake: start: cancelled")
      var manifest = CloudDevelopmentContractManifest(
        runID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        sourceRevision: String(repeating: "a", count: 40), harnessRevision: String(repeating: "a", count: 40),
        accountFingerprint: String(repeating: "b", count: 64), startedAt: Date(timeIntervalSince1970: 0),
        workDeadline: Date(timeIntervalSince1970: 1800), cleanupDeadline: Date(timeIntervalSince1970: 2400), zones: [zone.name])
      manifest.results["baseline"] = "failed-or-inconclusive: \(safe)"
      try evidence.write(manifest, named: "manifest.json")
      let saved = try object(root.appendingPathComponent("manifest.json"))
      let results = try XCTUnwrap(saved["results"] as? [String: String])
      XCTAssertEqual(results["baseline"], "failed-or-inconclusive: fake: start: cancelled")
    }
  }

  func testCancellationAndIndependentCleanupFailureKeepBothCausesDurably() async throws {
    let root = scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let zone = CloudZoneID(name: "snipsnap-contract-cancelled-with-cleanup", ownerName: "owner")
    let evidence = try CloudDevelopmentContractEvidence(directory: root, zoneNames: [zone.name])
    let retainedCleanup = Mutex<CloudDevelopmentCleanupFailure?>(nil)
    do {
      try await CloudDevelopmentTransportContract.runWithCleanup(operation: {
        try await self.cancelledBaseline(zone: zone)
      }, cleanup: {
        do {
          _ = try await CloudDevelopmentTransportContract.cleanupZones([zone], validateAccount: {},
            delete: { _ in throw CKError(.permissionFailure) }, exists: { _ in true })
        } catch let failure as CloudDevelopmentCleanupFailure {
          retainedCleanup.withLock { $0 = failure }
          throw failure
        }
      })
      XCTFail("Cancellation and independent cleanup failure must both escape")
    } catch {
      let safe = CloudDevelopmentAtomicContract.safe(error)
      XCTAssertTrue(safe.contains("operation: fake: start: cancelled"))
      XCTAssertTrue(error.localizedDescription.contains("operation: fake: start: cancelled"))
      XCTAssertTrue(safe.contains("cleanup: snipsnap-contract-cancelled-with-cleanup"))
      XCTAssertTrue(safe.contains("zoneCleanupWasNotConfirmed"))
      XCTAssertTrue(safe.contains("CKError(10)"))
      try evidence.write(["failure": safe], named: "failure.json")
      let failure = try object(root.appendingPathComponent("failure.json"))
      XCTAssertTrue((failure["failure"] as? String)?.contains("operation: fake: start: cancelled") == true)
      let cleanup = try XCTUnwrap(retainedCleanup.withLock { $0 })
      try evidence.write(cleanup, named: "cleanup.json")
      let saved = try object(root.appendingPathComponent("cleanup.json"))
      let outcomes = try XCTUnwrap(saved["outcomes"] as? [[String: Any]])
      XCTAssertEqual(outcomes.count, 1)
      let outcome = try XCTUnwrap(outcomes.first)
      XCTAssertEqual(outcome["zoneName"] as? String, "snipsnap-contract-cancelled-with-cleanup")
      XCTAssertEqual(outcome["verifiedAbsent"] as? Bool, false)
      let attempts = try XCTUnwrap(outcome["attempts"] as? [[String: Any]])
      XCTAssertEqual(attempts.compactMap { $0["number"] as? Int }, [1, 1, 2, 2, 3, 3])
      XCTAssertEqual(attempts.compactMap { $0["operation"] as? String }, ["delete", "read", "delete", "read", "delete", "read"])
      XCTAssertEqual(attempts.compactMap { $0["result"] as? String }, ["CKError(10)", "present", "CKError(10)", "present", "CKError(10)", "present"])
    }
  }

  func testRecoveredCleanupAttemptRetainsCancellationInDurableHistory() async throws {
    let root = scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let zone = CloudZoneID(name: "snipsnap-contract-cancelled-cleanup-attempt", ownerName: "owner")
    let evidence = try CloudDevelopmentContractEvidence(directory: root, zoneNames: [zone.name])
    let deletes = Mutex(0), reads = Mutex(0)
    let outcomes = try await CloudDevelopmentTransportContract.cleanupZones([zone], validateAccount: {}, delete: { _ in
      let number = deletes.withLock { $0 += 1; return $0 }
      if number == 1 { throw CancellationError() }
    }, exists: { _ in reads.withLock { $0 += 1; return $0 == 1 } })
    try evidence.write(outcomes, named: "cleanup.json")
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("cleanup.json"))) as? [[String: Any]])
    XCTAssertEqual(saved.count, 1)
    let outcome = try XCTUnwrap(saved.first)
    XCTAssertEqual(outcome["zoneName"] as? String, "snipsnap-contract-cancelled-cleanup-attempt")
    XCTAssertEqual(outcome["verifiedAbsent"] as? Bool, true)
    let attempts = try XCTUnwrap(outcome["attempts"] as? [[String: Any]])
    XCTAssertEqual(attempts.compactMap { $0["number"] as? Int }, [1, 1, 2, 2])
    XCTAssertEqual(attempts.compactMap { $0["operation"] as? String }, ["delete", "read", "delete", "read"])
    XCTAssertEqual(attempts.compactMap { $0["result"] as? String }, ["cancelled", "present", "ok", "absent"])
  }

  private func cancelledBaseline(zone: CloudZoneID) async throws {
    try await CloudDevelopmentTransportContract.exercise(transport: BaselineFault(.cancellation),
      reader: BaselineFault(.cancellation), name: "fake", zone: zone, drafts: [])
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

// Live and account-free planner callers use the same DEBUG orchestration.
enum ContractPlannerTestDriver {
  static func bootstrap(_ coordinator: CloudFullSyncCoordinator, transport: any CloudRecordTransport,
    zones: Set<CloudZoneID>, validate: @escaping @Sendable () async throws -> Void) async throws {
    try await CloudDevelopmentAtomicContract.preparePlanner(coordinator, transport: transport, zones: zones, validate: validate)
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
  let requiredZones: Set<CloudZoneID>
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
    self.server = server; self.data = data; self.account = account; requiredZones = namespace.zones
    base = FakeCloudRecordTransport(server: server, namespace: namespace, automaticallyFetchedZones: [data])
  }
  func injectAccountNoticeOnFetch(changed: Bool) { onFetch = changed }
  func changeAccountAfterFetchConfirmation() { changeAfterFetch = true }
  func observations() -> (noticeConfirmed: Bool, noticeID: UUID?, sendsAfterChange: Int) { (noticeConfirmed, noticeID, sendsAfterChange) }
  func start(state: CloudEngineStateEnvelope?) async throws { try await base.start(state: state) }
  func reset() async { await base.reset() }
  func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch {
    if !creations.isEmpty { return try await base.fetch(scope: scope) }
    var missing = requiredZones.subtracting(confirmedZones)
    for zone in requiredZones {
      if !(await server.hasZone(zone)) { missing.insert(zone) }
    }
    if !missing.isEmpty { await base.failNextFetchedZone(data, failure: .zoneMissing) }
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
    creations[sent.id] = Set(sent.databaseEvents.compactMap { event in
      guard case .zoneSaved(let zone) = event, batch.zonesToSave.contains(zone) else { return nil }
      return zone
    })
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

private struct BaselineAdmissionFixture: Sendable {
  let root: URL
  let zone = CloudZoneID(name: "snipsnap-contract-account-admission", ownerName: "owner")
  let account = Wave1Account()
  let server = FakeCloudServer()
  let writer: BaselineAdmissionTransport
  let reader: BaselineAdmissionTransport
  let text: CloudRecordDraft
  let payload: CloudRecordDraft

  init(writerTrigger: BaselineAdmissionTransport.Trigger = .none,
    readerTrigger: BaselineAdmissionTransport.Trigger = .none) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-admission-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("original.bin")
    try Data([0, 1, 255, 128, 42]).write(to: source)
    text = .text(id: .init(zone: zone, name: "00000000-0000-0000-0000-000000000062"),
      snipID: UUID(uuidString: "00000000-0000-0000-0000-000000000061")!, text: "Keep the manifest account")
    payload = .init(id: .init(zone: zone, name: "00000000-0000-0000-0000-000000000063"),
      recordType: "AttachmentPayload", schemaVersion: 1, routingFields: ["schemaVersion": .int64(1)],
      encryptedFields: [:], assetFields: ["payload": CloudAssetUpload(fileURL: source)])
    writer = BaselineAdmissionTransport(server: server, zone: zone, account: account, trigger: writerTrigger)
    reader = BaselineAdmissionTransport(server: server, zone: zone, account: account, trigger: readerTrigger)
  }

  func exercise(drafts: [CloudRecordDraft]) async throws {
    try await CloudDevelopmentTransportContract.exercise(transport: writer, reader: reader,
      name: "CloudKit", zone: zone, drafts: drafts, validateAccount: { try account.validate() })
  }
  func failure(drafts: [CloudRecordDraft]) async -> String? {
    do { try await exercise(drafts: drafts); return nil }
    catch { return CloudDevelopmentAtomicContract.safe(error) }
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

// Observe real fake-server effects; inject account changes only after an awaited operation completes.
private actor BaselineAdmissionTransport: CloudRecordTransport {
  enum Trigger: Sendable { case none, start, initialFetchConfirmed, contentRead }
  enum Write: Equatable, Sendable { case zone(CloudZoneID), save(CloudRecordID), delete(CloudRecordID) }
  struct Observation: Sendable {
    var started = false
    var initialFetchConfirmed = false
    var writes: [Write] = []
    var records: [CloudRecordSnapshot] = []
    var assets: [Data] = []
  }
  let base: FakeCloudRecordTransport
  let account: Wave1Account
  let trigger: Trigger
  var observed = Observation()
  var initialFetchID: UUID?

  init(server: FakeCloudServer, zone: CloudZoneID, account: Wave1Account, trigger: Trigger) {
    base = FakeCloudRecordTransport(server: server, automaticallyFetchedZones: [zone])
    self.account = account; self.trigger = trigger
  }
  func observation() -> Observation { observed }
  func start(state: CloudEngineStateEnvelope?) async throws {
    try await base.start(state: state)
    observed.started = true
    if case .start = trigger { account.changed.withLock { $0 = true } }
  }
  func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
    observed.writes += batch.zonesToSave.map(Write.zone)
    observed.writes += batch.operations.map { operation -> Write in
      switch operation { case .save(let draft): .save(draft.id); case .delete(let id, _): .delete(id) }
    }
    return try await base.send(batch)
  }
  func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch {
    let batch = try await base.fetch(scope: scope)
    if batch.isInitialFetch { initialFetchID = batch.id }
    for item in batch.items {
      if case .record(let snapshot) = item {
        observed.records.append(snapshot)
        if case .contentRead = trigger, snapshot.assetFields.isEmpty { account.changed.withLock { $0 = true } }
      }
    }
    return batch
  }
  func pendingEvent() async -> CloudRecordTransportEvent? {
    let transport: any CloudRecordTransport = base
    return await transport.pendingEvent()
  }
  func confirmApplied(_ id: UUID) async throws {
    try await base.confirmApplied(id)
    if id == initialFetchID {
      observed.initialFetchConfirmed = true
      if case .initialFetchConfirmed = trigger { account.changed.withLock { $0 = true } }
    }
  }
  func fetchRecord(_ id: CloudRecordID, fields: Set<String>) async throws -> CloudRecordSnapshot? {
    try await base.fetchRecord(id, fields: fields)
  }
  func fetchAsset(_ id: CloudRecordID, field: String, destination: CloudAssetDestination) async throws -> CloudAssetReceipt? {
    let receipt = try await base.fetchAsset(id, field: field, destination: destination)
    if let receipt {
      observed.assets.append(try Data(contentsOf: receipt.fileURL))
      if case .contentRead = trigger { account.changed.withLock { $0 = true } }
    }
    return receipt
  }
}

private struct BaselineFault: CloudRecordTransport {
  enum Mode: Sendable { case creation, cloud, cancellation }
  let mode: Mode
  init(_ mode: Mode) { self.mode = mode }
  func start(state: CloudEngineStateEnvelope?) async throws {
    if case .cancellation = mode { throw CancellationError() }
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
