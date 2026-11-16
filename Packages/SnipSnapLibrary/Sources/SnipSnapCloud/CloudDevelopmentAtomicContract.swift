#if DEBUG
import CloudKit
import CryptoKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence
import Synchronization

/// A finite Development experiment, not a CloudKit snapshot-isolation guarantee.
final class CloudDevelopmentAtomicContract: Sendable {
  typealias Evidence = CloudDevelopmentContractEvidence
  typealias Failure = CloudDevelopmentContractFailure
  private let database: CKDatabase
  private let evidence: Evidence
  private let budget: CloudDevelopmentContractBudget
  private let manifest: Mutex<CloudDevelopmentContractManifest>
  private let validateAccount: @Sendable () async throws -> Void
  private let left: CloudKitRecordTransport
  private let right: CloudKitRecordTransport
  private let zones: [CloudZoneID]

  static func run(containerIdentifier: String, evidenceDirectory: URL,
    sourceRevision: String, harnessRevision: String, sessionStartedAt: Date) async throws {
    let runID = UUID()
    let zones = ["metadata", "payload", "planner3-metadata", "planner3-payload", "planner5-metadata", "planner5-payload"].map {
      CloudZoneID(name: "snipsnap-contract-\(runID.uuidString.lowercased())-\($0)", ownerName: CKCurrentUserDefaultName)
    }
    let evidence = try Evidence(directory: evidenceDirectory, zoneNames: Set(zones.map(\.name)))
    let budget = CloudDevelopmentContractBudget(workDeadline: sessionStartedAt.addingTimeInterval(30 * 60),
      cleanupDeadline: sessionStartedAt.addingTimeInterval(40 * 60))
    try budget.check("before-account")
    guard sourceRevision.count == 40, harnessRevision.count == 40,
      sourceRevision.allSatisfy(\.isHexDigit), harnessRevision.allSatisfy(\.isHexDigit)
    else { throw Failure.invalidEvidence }
    let container = CKContainer(identifier: containerIdentifier)
    let account = try await budget.perform("account") { try await container.userRecordID() }
    let validate: @Sendable () async throws -> Void = {
      guard try await container.userRecordID() == account else {
        throw CloudDevelopmentTransportContract.ContractError.accountChanged
      }
    }
    let initial = CloudDevelopmentContractManifest(runID: runID, sourceRevision: sourceRevision,
      harnessRevision: harnessRevision, accountFingerprint: Evidence.fingerprint(account.recordName),
      startedAt: sessionStartedAt, workDeadline: budget.workDeadline, cleanupDeadline: budget.cleanupDeadline,
      zones: zones.map(\.name))
    // Durable exact-zone/account context exists BEFORE any zone or record write.
    try evidence.write(initial, named: "manifest.json")
    let contract = Self(database: container.privateCloudDatabase, evidence: evidence,
      budget: budget, manifest: initial, zones: zones, validateAccount: validate)
    try await CloudDevelopmentTransportContract.runWithCleanup(operation: {
      do { try await budget.perform("overall", seconds: 1800) { try await contract.exercise() } }
      catch { throw contract.preservedFailure(error) }
    }, cleanup: {
      // User cancellation must not prevent an attempt at same-account exact-zone cleanup.
      try await Task.detached { try await contract.cleanup() }.value
    })
  }

  init(database: CKDatabase, evidence: Evidence, budget: CloudDevelopmentContractBudget,
    manifest: CloudDevelopmentContractManifest, zones: [CloudZoneID],
    validateAccount: @escaping @Sendable () async throws -> Void) {
    self.database = database; self.evidence = evidence; self.budget = budget
    self.manifest = Mutex(manifest); self.zones = zones; self.validateAccount = validateAccount
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "maintainer-contract",
      generation: manifest.runID, zones: Set(zones.prefix(2)))
    left = Self.transport(database, namespace: namespace, evidence: evidence, client: "L")
    right = Self.transport(database, namespace: namespace, evidence: evidence, client: "R")
  }

  static func transport(_ database: CKDatabase, namespace: CloudSyncNamespace,
    evidence: Evidence, client: String, fetchedZones: Set<CloudZoneID>? = nil) -> CloudKitRecordTransport {
    CloudKitRecordTransport(namespace: namespace, automaticallyFetchedZones: fetchedZones,
      diagnostics: AppDiagnosticRecorder(record: { _ in }), readRecords: { ids, keys in try await database.records(for: ids, desiredKeys: keys) },
      makeEngine: { serialization, automatic, delegate in
        CloudDevelopmentEngineObserver(transport: delegate, evidence: evidence, client: client) { observer in
          var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: serialization, delegate: observer)
          configuration.automaticallySync = automatic
          return CKSyncEngine(configuration)
        }
      })
  }

  func persist() throws {
    try evidence.write(manifest.withLock { $0 }, named: "manifest.json")
    try evidence.flush()
  }

  private func preservedFailure(_ original: Error) -> CloudDevelopmentTransportContract.StepFailure {
    var causes = [CloudDevelopmentTransportContract.Cause(original)]
    do { try persist() } catch { causes.append(.evidenceWrite) }
    return CloudDevelopmentTransportContract.StepFailure(stage: "atomic-contract", causes: causes)
  }

  private func phase(_ name: String, operation: @escaping @Sendable () async throws -> Void) async throws {
    evidence.begin(name)
    do {
      try await budget.perform(name) { try await self.validateAccount(); try await operation() }
      manifest.withLock { $0.results[name] = "pass" }
    } catch {
      manifest.withLock { $0.results[name] = "failed-or-inconclusive: \(Self.safe(error))" }
      throw preservedFailure(error)
    }
    try persist()
  }

  private func cleanup() async throws {
    await left.reset(); await right.reset()
    do {
      try await budget.perform("cleanup", seconds: 600, cleanup: true) {
        _ = try await CloudDevelopmentTransportContract.cleanupZones(self.zones, validateAccount: self.validateAccount,
        delete: { zone in
          try self.budget.check("cleanup", cleanup: true)
          _ = try await self.database.deleteRecordZone(withID: CloudKitRecordMapper.zoneID(for: zone))
        }, exists: { zone in
          try self.budget.check("cleanup", cleanup: true)
          do { _ = try await self.database.recordZone(for: CloudKitRecordMapper.zoneID(for: zone)); return true }
          catch let error as CKError where error.code == .zoneNotFound { return false }
        }, checkBudget: { try self.budget.check("cleanup", cleanup: true) }, recordOutcome: { outcome in
          self.manifest.withLock {
            $0.cleanup[outcome.zoneName] = outcome.verifiedAbsent ? "verified-absent" : "UNRESOLVED"
            $0.cleanupOutcomes[outcome.zoneName] = outcome
          }
          try self.persist()
        })
      }
    } catch {
      throw preservedFailure(error)
    }
    try persist()
  }

  static func safe(_ error: Error) -> String {
    CloudDevelopmentTransportContract.Cause(error).text
  }

  static func preparePlanner(_ coordinator: CloudFullSyncCoordinator, transport: any CloudRecordTransport,
    zones: Set<CloudZoneID>, validate: @escaping @Sendable () async throws -> Void) async throws {
    try await validate()
    try await transport.start(state: nil)
    try await validate()
    let created = try await transport.send(CloudOutboundBatch(operations: [], zonesToSave: zones))
    for zone in zones {
      try require(created.databaseEvents.contains(.zoneSaved(zone)), "planner-zone-create-not-confirmed")
    }
    try await CloudDevelopmentTransportContract.confirm(.sent(created), transport: transport, validateAccount: validate)
    let fetched = try await coordinator.fetchRemote(beforeApply: validate)
    try require(!fetched.blocksOutbound, "planner-initial-fetch-blocked")
    try await sendPlanner(coordinator, validate: validate)
  }

  static func sendPlanner(_ coordinator: CloudFullSyncCoordinator,
    validate: @escaping @Sendable () async throws -> Void) async throws {
    try await validate()
    _ = try await coordinator.sendPendingUntilSettled(beforeApply: validate, beforeSend: { _ in try await validate() })
  }

  private func exercise() async throws {
    try await phase("baseline") {
      let source = self.evidence.directory.appendingPathComponent("baseline.bin")
      try Data((0..<8192).map { UInt8($0 % 251) }).write(to: source)
      let drafts = [CloudRecordDraft.text(id: .random(in: self.zones[0]), snipID: UUID(), text: "Snip Snap Cloud Dev transport contract"),
        CloudRecordDraft(id: .random(in: self.zones[0]), recordType: CloudAttachmentRecordCodec.payloadRecordType,
          schemaVersion: 1, routingFields: ["schemaVersion": .int64(1)], encryptedFields: [:],
          assetFields: [CloudAttachmentRecordCodec.assetField: CloudAssetUpload(fileURL: source)])]
      let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "maintainer-contract",
        generation: UUID(), zones: [self.zones[0]])
      let fake = FakeCloudServer()
      try await CloudDevelopmentTransportContract.exercise(transport: FakeCloudRecordTransport(server: fake, namespace: namespace),
        reader: FakeCloudRecordTransport(server: fake, namespace: namespace), name: "fake", zone: self.zones[0], drafts: drafts)
      let l = Self.transport(self.database, namespace: namespace, evidence: self.evidence, client: "baseline-L")
      let r = Self.transport(self.database, namespace: namespace, evidence: self.evidence, client: "baseline-R")
      do {
        try await CloudDevelopmentTransportContract.exercise(transport: l, reader: r, name: "CloudKit",
          zone: self.zones[0], drafts: drafts, validateAccount: self.validateAccount)
      } catch { await l.reset(); await r.reset(); throw error }
      await l.reset(); await r.reset()
    }
    try await phase("setup") {
      try await self.start(self.left, self.right, zones: Set(self.zones.prefix(2)))
    }
    try await phase("9-capability") {
      let zone = try await self.database.recordZone(for: CloudKitRecordMapper.zoneID(for: self.zones[0]))
      try Self.require(zone.capabilities.contains(.atomic), "zone-without-atomic-capability")
      self.manifest.withLock { $0.observations["9-capability"] = ["zone": self.zones[0].name, "atomic": String(zone.capabilities.contains(.atomic))] }
    }
    // Setups use fresh IDs and confirmed bootstrap sends outside each measured window.
    let one = try await fixture(label: "one", snipID: Self.snip(1))
    let companion = try await fixture(label: "later", snipID: Self.snip(2))
    let currentOne = try await peerReorder(one)
    try await phase("1-3-4-5-one-stale") {
      let old = try await self.read(one)
      let bad = self.drafts(one, order: [1, 0, 2, 3], bases: currentOne, stale: [0])
      let good = self.drafts(companion, order: [1, 0, 2, 3], bases: companion.accepted)
      _ = try await self.send(self.left, bad + good)
      try await self.unchanged(one, before: old)
      try await self.order(companion, expected: [1, 0, 2, 3])
      let trace = try self.evidence.entries(phase: "1-3-4-5-one-stale", client: "L")
      try Self.failedGroup(trace, ids: one.ids.map(self.evidence.name), stale: [self.evidence.name(one.ids[0])], expectedTags: self.tags(old))
      try Self.eventsMatchBatches(trace)
      let batches = trace.filter { $0.kind == "provider-batch" }
      try Self.require(batches.count == 2 && batches.allSatisfy { $0.atomic == true }, "provider-did-not-continue-after-failure")
      let failedEvent = trace.first { $0.kind == "sent-event-before" && Set($0.ids) == Set(one.ids.map(self.evidence.name)) }
      try Self.require(failedEvent.map { batches[1].sequence > $0.sequence } == true
        && trace.filter { $0.kind == "send-start" }.count == 1, "provider-continuation-not-in-same-send-after-failure")
      try Self.require(trace.contains { $0.kind == "send-return" || $0.kind.hasPrefix("send-throw:") }, "raw-send-outcome-missing")
      try Self.require(trace.contains { $0.kind == "sent-event-after" }, "post-forward-pending-missing")
      self.observeSend(trace, phase: "1-3-4-5-one-stale")
    }
    let triple = try await fixture(label: "three", snipID: Self.snip(3))
    let currentTriple = try await peerReorder(triple)
    try await phase("2-three-stale") {
      let old = try await self.read(triple)
      _ = try await self.send(self.left, self.drafts(triple, order: [1, 0, 2, 3], bases: currentTriple, stale: [0, 1, 2]))
      try await self.unchanged(triple, before: old)
      try Self.failedGroup(self.evidence.entries(phase: "2-three-stale", client: "L"),
        ids: triple.ids.map(self.evidence.name), stale: Set(triple.ids.prefix(3).map(self.evidence.name)), expectedTags: self.tags(old))
      let event = try self.evidence.entries(phase: "2-three-stale", client: "L").first { $0.kind == "sent-event-before" }
      self.manifest.withLock { $0.observations["2-three-stale"] = event?.errors.mapValues { String($0) } }
    }
    try await unchangedCompanion()
    try await isolation(failingOrdinary: true)
    try await isolation(failingOrdinary: false)
    for sample in 0..<3 { try await fetchSample(sample) }
    try await planner(count: 3, zones: Array(zones[2...3]))
    try await planner(count: 5, zones: Array(zones[4...5]))
    let windows = Dictionary(grouping: try evidence.entries(), by: { "\($0.phase)|\($0.client)" })
    for entries in windows.values {
      let atomic = entries.filter { $0.kind == "provider-batch" && $0.atomic == true }
      let ids = Set(atomic.flatMap(\.ids))
      let terminal = entries.filter { $0.kind == "sent-event-before" && !Set($0.ids).isDisjoint(with: ids) }
      try Self.eventsMatchBatches(atomic + terminal)
    }
    manifest.withLock { $0.results["3-all-atomic-events"] = "pass" }
  }

  private func start(_ l: CloudKitRecordTransport, _ r: CloudKitRecordTransport, zones: Set<CloudZoneID>) async throws {
    try await l.start(state: nil); try await r.start(state: nil)
    let created = try await l.send(CloudOutboundBatch(operations: [], zonesToSave: zones))
    for zone in zones { try Self.require(created.databaseEvents.contains(.zoneSaved(zone)), "zone-create-not-confirmed") }
    try await confirm(.sent(created), transport: l)
    for client in [l, r] {
      let fetched = try await client.fetch(scope: .all)
      try Self.require(!CloudSyncIssueError.blocksOutbound(in: .fetched(fetched)), "initial-fetch-blocked")
      try await confirm(.fetched(fetched), transport: client)
    }
  }

  private func confirm(_ batch: CloudSyncBatch, transport: any CloudRecordTransport) async throws {
    try await CloudDevelopmentTransportContract.confirm(batch, transport: transport, validateAccount: validateAccount)
  }
  @discardableResult
  private func send(_ transport: CloudKitRecordTransport, _ drafts: [CloudRecordDraft]) async throws -> [CloudRecordSnapshot] {
    try budget.check("send"); try await validateAccount()
    let batch = try await transport.send(CloudOutboundBatch(operations: drafts.map(CloudOutboundOperation.save)))
    try await confirm(.sent(batch), transport: transport)
    return batch.items.compactMap { if case .saved(let record) = $0 { record } else { nil } }
  }

  struct Fixture: Sendable {
    let ids: [CKRecord.ID]
    let snipID: UUID
    let accepted: [CloudRecordSnapshot]
    let original: [CloudRecordDraft]
    let payloads: [CloudTextStorageIdentity]
  }
  private func fixture(label: String, snipID: UUID) async throws -> Fixture {
    try await budget.perform("setup-\(label)") { try await self.makeFixture(label: label, snipID: snipID) }
  }
  private func makeFixture(label: String, snipID: UUID) async throws -> Fixture {
    evidence.begin("setup-\(label)"); try budget.check(label)
    let source = evidence.directory.appendingPathComponent("baseline.bin")
    var payloads: [CloudTextStorageIdentity] = []
    for _ in 0..<4 {
      let identity = CloudTextStorageIdentity(zoneName: zones[1].name, ownerName: zones[1].ownerName, recordName: UUID().uuidString.lowercased())
      payloads.append(identity)
    }
    let uploads = payloads.map { CloudRecordDraft(id: CloudAttachmentRecordCodec.recordID($0),
      recordType: CloudAttachmentRecordCodec.payloadRecordType, schemaVersion: 1,
      routingFields: ["schemaVersion": .int64(1)], encryptedFields: [:],
      assetFields: [CloudAttachmentRecordCodec.assetField: CloudAssetUpload(fileURL: source)]) }
    try Self.require(try await send(left, uploads).count == 4, "fixture-payload-not-accepted")
    let ids = (0..<4).map { _ in CKRecord.ID(recordName: "a-\(UUID().uuidString.lowercased())", zoneID: CloudKitRecordMapper.zoneID(for: zones[0])) }
    var metadata: [CloudRecordDraft] = []
    for i in 0..<4 {
      let attachmentID = UUID(uuidString: String(ids[i].recordName.dropFirst(2)))!
      let value = CloudAttachmentMetadataValue(attachmentID: attachmentID, snipID: snipID, position: i,
        fileName: ["A.txt", "B.txt", "C.txt", "D.txt"][i], contentType: "public.plain-text", byteCount: 8192,
        sha256: Data((0..<8192).map { UInt8($0 % 251) }).sha256ForContract,
        payloadIdentity: payloads[i])
      metadata.append(try CloudAttachmentRecordCodec.metadataDraft(CloudAttachmentPublication(metadata: value,
        metadataIdentity: CloudFullSyncPersistence.storageIdentity(CloudKitRecordMapper.id(for: ids[i])),
        sourceURL: nil, payloadAccepted: true, payloadShadowData: nil, metadataAccepted: false,
        metadataShadowData: nil, revision: 1)))
    }
    let accepted = try await send(left, metadata)
    try Self.require(accepted.count == 4 && Set(accepted.map { CloudKitRecordMapper.recordID(for: $0.id) }) == Set(ids),
      "fixture-metadata-not-accepted")
    let ordered = ids.compactMap { id in accepted.first { CloudKitRecordMapper.recordID(for: $0.id) == id } }
    for i in ids.indices {
      try Self.require(ordered[i].encryptedFields == metadata[i].encryptedFields, "bootstrap-differs-from-original-draft")
    }
    return Fixture(ids: ids, snipID: snipID, accepted: ordered, original: metadata, payloads: payloads)
  }

  private func drafts(_ f: Fixture, order: [Int], bases: [CloudRecordSnapshot], stale: Set<Int> = []) -> [CloudRecordDraft] {
    f.ids.indices.map { index in
      let base = stale.contains(index) ? f.accepted[index] : bases[index]
      var fields = f.original[index].encryptedFields
      fields["position"] = .int64(Int64(order.firstIndex(of: index)!))
      return CloudRecordDraft(id: CloudKitRecordMapper.id(for: f.ids[index]), recordType: CloudAttachmentRecordCodec.metadataRecordType,
        schemaVersion: 1, routingFields: ["schemaVersion": .int64(1)], encryptedFields: fields, base: base.shadow)
    }
  }
  private func peerReorder(_ f: Fixture) async throws -> [CloudRecordSnapshot] {
    try await budget.perform("peer-reorder") { try await self.performPeerReorder(f) }
  }
  private func performPeerReorder(_ f: Fixture) async throws -> [CloudRecordSnapshot] {
    let saved = try await send(right, drafts(f, order: [3, 2, 1, 0], bases: f.accepted))
    try Self.require(saved.count == 4, "peer-reorder-not-accepted")
    try await order(f, expected: [3, 2, 1, 0])
    return try await read(f)
  }
  private func read(_ f: Fixture) async throws -> [CloudRecordSnapshot] {
    try await validateAccount()
    let records = try await database.records(for: f.ids, desiredKeys: nil)
    return try f.ids.map { id in
      guard let result = records[id] else { throw Failure.oracle("server-record-missing") }
      return try CloudKitRecordMapper.snapshot(result.get())
    }
  }
  private func unchanged(_ f: Fixture, before: [CloudRecordSnapshot]) async throws {
    let after = try await read(f)
    try Self.require(after.map(\.encryptedFields) == before.map(\.encryptedFields)
      && after.map { try? $0.shadow.record().recordChangeTag } == before.map { try? $0.shadow.record().recordChangeTag }, "failed-atomic-group-changed-server")
  }
  private func order(_ f: Fixture, expected: [Int]) async throws {
    let records = try await read(f)
    try Self.literalOrder(records, ids: f.ids.map(CloudKitRecordMapper.id(for:)), expected: expected)
    for i in records.indices {
      var original = f.original[i].encryptedFields
      original["position"] = .int64(Int64(expected.firstIndex(of: i)!))
      try Self.require(records[i].encryptedFields == original, "order-changed-original-content-or-payload")
    }
    try Self.originalPayloads(records, fixture: f)
  }

  private static func originalPayloads(_ records: [CloudRecordSnapshot], fixture f: Fixture) throws {
    for i in f.ids.indices {
      guard let record = records.first(where: { CloudKitRecordMapper.recordID(for: $0.id) == f.ids[i] }) else {
        throw Failure.oracle("original-payload-member-missing")
      }
      let fields = record.encryptedFields
      try require(fields["byteCount"] == .int64(8192)
        && fields["sha256"] == .data(Data((0..<8192).map { UInt8($0 % 251) }).sha256ForContract)
        && fields["payloadZoneName"] == .string(f.payloads[i].zoneName)
        && fields["payloadOwnerName"] == .string(f.payloads[i].ownerName)
        && fields["payloadRecordName"] == .string(f.payloads[i].recordName), "original-payload-reference-or-digest-differs")
    }
  }

  static func require(_ condition: Bool, _ reason: String) throws {
    guard condition else { throw Failure.oracle(reason) }
  }
  static func snip(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
  }
  static func literalOrder(_ records: [CloudRecordSnapshot], ids: [CloudRecordID], expected: [Int]) throws {
    try require(ids.count == 4 && records.count == 4 && Set(records.map(\.id)) == Set(ids)
      && expected.sorted() == [0, 1, 2, 3], "literal-order-membership")
    for i in ids.indices {
      guard let record = records.first(where: { $0.id == ids[i] }) else { throw Failure.oracle("order-member-missing") }
      try require(record.encryptedFields["position"] == .int64(Int64(expected.firstIndex(of: i)!)), "literal-order-differs")
      try require(record.encryptedFields["fileName"] == .string(["A.txt", "B.txt", "C.txt", "D.txt"][i]), "literal-name-differs")
      try require(record.encryptedFields["contentType"] == .string("public.plain-text"), "literal-type-differs")
    }
  }
  private func tags(_ records: [CloudRecordSnapshot]) throws -> [String: String] {
    try Dictionary(uniqueKeysWithValues: records.map { record in
      guard let tag = try record.shadow.record().recordChangeTag else { throw Failure.oracle("server-tag-missing") }
      return (evidence.name(CloudKitRecordMapper.recordID(for: record.id)), Evidence.fingerprint(tag))
    })
  }
  static func failedGroup(_ trace: [Evidence.Entry], ids: [String], stale: Set<String>, expectedTags: [String: String]) throws {
    let events = trace.filter { $0.kind == "sent-event-before" && !Set($0.ids).isDisjoint(with: ids) }
    try require(events.count == 1 && events[0].ids.count == ids.count && Set(events[0].ids) == Set(ids), "failure-event-membership")
    let errors = events[0].errors
    try require(Set(errors.keys) == Set(ids), "failure-error-membership")
    var conflicts = 0
    for id in ids {
      if errors[id] == CKError.Code.serverRecordChanged.rawValue {
        try require(stale.contains(id) && expectedTags[id] != nil && events[0].serverTags[id] == expectedTags[id], "conflict-without-stale-server-record")
        conflicts += 1
      } else {
        try require(errors[id] == CKError.Code.batchRequestFailed.rawValue, "unexpected-atomic-error")
      }
    }
    try require(conflicts > 0, "no-stale-member-conflict")
  }
  static func eventsMatchBatches(_ trace: [Evidence.Entry]) throws {
    let batches = trace.filter { $0.kind == "provider-batch" }
    let events = trace.filter { $0.kind == "sent-event-before" }
    try require(events.count == batches.count, "not-one-event-per-batch")
    try require(Dictionary(grouping: batches, by: \.ids).mapValues(\.count)
      == Dictionary(grouping: events, by: \.ids).mapValues(\.count), "event-crossed-batch-boundary")
  }

  private func observeSend(_ trace: [Evidence.Entry], phase: String) {
    var observed: [String: String] = [:]
    for entry in trace where entry.kind == "sent-event-before" || entry.kind == "sent-event-after"
      || entry.kind == "send-return" || entry.kind.hasPrefix("send-throw:") {
      observed["\(entry.sequence)-\(entry.kind)"] = entry.pending.joined(separator: "|")
    }
    manifest.withLock { $0.observations[phase] = observed }
  }

  private func changed(_ draft: CloudRecordDraft, key: String, value: CloudFieldValue) -> CloudRecordDraft {
    var fields = draft.encryptedFields; fields[key] = value
    return CloudRecordDraft(id: draft.id, recordType: draft.recordType, schemaVersion: draft.schemaVersion,
      routingFields: draft.routingFields, encryptedFields: fields, base: draft.base)
  }

  private func unchangedCompanion() async throws {
    try await budget.perform("unchangedCompanion-with-setup", seconds: 90) { try await self.executeUnchangedCompanion() }
  }
  private func executeUnchangedCompanion() async throws {
    let f = try await fixture(label: "companion", snipID: Self.snip(4))
    // Two real edits restore C's original values and position, but not its accepted tag.
    let original = drafts(f, order: [0, 1, 2, 3], bases: f.accepted)[2]
    try Self.require(try await send(right, [changed(original, key: "fileName", value: .string("temporary-C.txt"))]).count == 1,
      "companion-peer-edit-failed")
    let intermediate = try await read(f)
    try Self.require(try await send(right, [drafts(f, order: [0, 1, 2, 3], bases: intermediate)[2]]).count == 1,
      "companion-peer-restore-failed")
    let current = try await read(f)
    try Self.require(current[2].encryptedFields == f.accepted[2].encryptedFields
      && (try current[2].shadow.record().recordChangeTag) != (try f.accepted[2].shadow.record().recordChangeTag),
      "companion-stale-tag-precondition")
    try await phase("6-unchanged-companion") {
      _ = try await self.send(self.left, self.drafts(f, order: [1, 0, 2, 3], bases: current, stale: [2]))
      try await self.unchanged(f, before: current)
      try Self.failedGroup(self.evidence.entries(phase: "6-unchanged-companion", client: "L"),
        ids: f.ids.map(self.evidence.name), stale: [self.evidence.name(f.ids[2])], expectedTags: self.tags(current))
      let accepted = try await self.send(self.left, self.drafts(f, order: [1, 0, 2, 3], bases: current))
      try Self.require(accepted.count == 4, "current-companion-not-accepted")
      let after = try await self.read(f)
      try await self.order(f, expected: [1, 0, 2, 3])
      try Self.require((try after[2].shadow.record().recordChangeTag) != (try current[2].shadow.record().recordChangeTag),
        "unchanged-current-companion-tag-did-not-advance")
    }
  }

  private func isolation(failingOrdinary: Bool) async throws {
    try await budget.perform("isolation-with-setup", seconds: 90) { try await self.executeIsolation(failingOrdinary: failingOrdinary) }
  }
  private func executeIsolation(failingOrdinary: Bool) async throws {
    let group = try await fixture(label: "isolation-group", snipID: Self.snip(failingOrdinary ? 5 : 7))
    let ordinary = try await fixture(label: "isolation-ordinary", snipID: Self.snip(failingOrdinary ? 6 : 8))
    let text = CloudRecordDraft.text(id: .random(in: zones[0]), snipID: UUID(), text: "original text")
    let textAccepted = try await send(left, [text])
    try Self.require(textAccepted.count == 1, "ordinary-text-bootstrap")
    let baseText = CloudRecordDraft(id: text.id, recordType: text.recordType, schemaVersion: text.schemaVersion,
      routingFields: text.routingFields, encryptedFields: text.encryptedFields, base: textAccepted[0].shadow)
    let oldMetadata = drafts(ordinary, order: [0, 1, 2, 3], bases: ordinary.accepted)[0]
    if failingOrdinary {
      try Self.require(try await send(right, [changed(baseText, key: "text", value: .string("peer text")),
        changed(oldMetadata, key: "fileName", value: .string("peer-A.txt"))]).count == 2, "ordinary-peer-edit")
    } else { _ = try await peerReorder(group) }
    let ordinaryBefore = try await read(ordinary)
    let groupBefore = try await read(group)
    let name = failingOrdinary ? "7-failed-ordinary" : "7-failed-atomic"
    try await phase(name) {
      let ordinaryDraft = self.changed(oldMetadata, key: "fileName", value: .string("local-A.txt"))
      let textDraft = self.changed(baseText, key: "text", value: .string("local text"))
      let saved = try await self.send(self.left, [textDraft, ordinaryDraft]
        + self.drafts(group, order: [1, 0, 2, 3], bases: group.accepted))
      let trace = try self.evidence.entries(phase: name, client: "L")
      try Self.eventsMatchBatches(trace)
      let batches = trace.filter { $0.kind == "provider-batch" }
      try Self.require(batches.count == 2 && batches[0].atomic == false && batches[1].atomic == true,
        "ordinary-atomic-membership-not-isolated")
      try Self.require(Set(batches[0].ids) == Set([self.evidence.name(CloudKitRecordMapper.recordID(for: text.id)),
        self.evidence.name(ordinary.ids[0])]), "ordinary-batch-membership")
      try Self.require(trace.contains { $0.kind == "send-return" || $0.kind.hasPrefix("send-throw:") }, "raw-send-result-missing")
      self.observeSend(trace, phase: name)
      if failingOrdinary {
        try Self.require(Set(saved.map(\.id)) == Set(group.ids.map(CloudKitRecordMapper.id(for:))), "ordinary-failure-leaked")
        try await self.order(group, expected: [1, 0, 2, 3])
        try await self.unchanged(ordinary, before: ordinaryBefore)
        let failures = trace.filter { $0.kind == "sent-event-before" }.flatMap { Array($0.errors.values) }
        try Self.require(failures.count == 2 && failures.allSatisfy { $0 == CKError.Code.serverRecordChanged.rawValue },
          "ordinary-stale-errors-differ")
      } else {
        try Self.require(Set(saved.map(\.id)) == Set([text.id, oldMetadata.id]), "atomic-failure-blocked-ordinary")
        try await self.unchanged(group, before: groupBefore)
        try Self.failedGroup(trace, ids: group.ids.map(self.evidence.name), stale: Set(group.ids.map(self.evidence.name)), expectedTags: self.tags(groupBefore))
      }
      let ordinaryAfter = try await self.read(ordinary)
      try Self.require(ordinaryAfter[0].encryptedFields["fileName"] == .string(failingOrdinary ? "peer-A.txt" : "local-A.txt")
        && ordinaryAfter[0].encryptedFields["position"] == .int64(0), "literal-ordinary-metadata-differs")
      let direct = try await self.database.records(for: [CloudKitRecordMapper.recordID(for: text.id)], desiredKeys: nil)
      let value = try CloudKitRecordMapper.snapshot(direct[CloudKitRecordMapper.recordID(for: text.id)]!.get())
      try Self.require(value.encryptedFields["text"] == .string(failingOrdinary ? "peer text" : "local text"), "literal-text-differs")
    }
  }

  private func fetchSample(_ sample: Int) async throws {
    try await budget.perform("fetchSample-with-setup", seconds: 90) { try await self.executeFetchSample(sample) }
  }
  private func executeFetchSample(_ sample: Int) async throws {
    let f = try await fixture(label: "fetch-\(sample)", snipID: Self.snip(10 + sample))
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "maintainer-contract",
      generation: UUID(), zones: Set(zones.prefix(2)))
    let reader = Self.transport(database, namespace: namespace, evidence: evidence, client: "snapshot-\(sample)")
    do {
      try await reader.start(state: nil)
      let initial = try await reader.fetch(scope: .all)
      try Self.require(!CloudSyncIssueError.blocksOutbound(in: .fetched(initial)), "snapshot-reader-initial-fetch-failed")
      try await confirm(.fetched(initial), transport: reader)
      try await phase("8-fetch-\(sample)") {
        let accepted = try await self.send(self.left, self.drafts(f, order: [1, 0, 2, 3], bases: f.accepted))
        try Self.require(accepted.count == 4, "fetch-fixture-write-not-accepted")
        let fetched = try await reader.fetch(scope: .all)
        try Self.require(!CloudSyncIssueError.blocksOutbound(in: .fetched(fetched)), "fetch-sample-failed-or-inconclusive")
        let records = fetched.items.compactMap { item -> CloudRecordSnapshot? in
          guard case .record(let record) = item, f.ids.map(CloudKitRecordMapper.id(for:)).contains(record.id) else { return nil }; return record
        }
        try Self.require(records.count == 4, "fetch-cycle-not-whole")
        try Self.literalOrder(records, ids: f.ids.map(CloudKitRecordMapper.id(for:)), expected: [1, 0, 2, 3])
        try Self.originalPayloads(records, fixture: f)
        try Self.require(self.tags(records) == self.tags(accepted), "fetch-did-not-return-this-write-tags")
        let observedTags = try self.tags(records)
        self.manifest.withLock { $0.observations["8-fetch-\(sample)"] = observedTags }
        let trace = try self.evidence.entries(phase: "8-fetch-\(sample)", client: "snapshot-\(sample)")
        try Self.require(trace.filter { $0.kind == "did-fetch" }.count == 1, "fetch-cycle-boundary-missing")
        let delivered = Set(trace.filter { $0.kind == "fetched-event" }.flatMap(\.ids))
        try Self.require(Set(f.ids.map(self.evidence.name)).isSubset(of: delivered), "raw-fetch-members-missing")
        try await self.confirm(.fetched(fetched), transport: reader)
        for identity in f.payloads {
          let target = self.evidence.directory.appendingPathComponent("download-\(UUID().uuidString)")
          try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
          defer { try? FileManager.default.removeItem(at: target) }
          guard let receipt = try await reader.fetchAsset(CloudAttachmentRecordCodec.recordID(identity),
            field: CloudAttachmentRecordCodec.assetField, destination: CloudAssetDestination(validating: target)),
            try Data(contentsOf: receipt.fileURL) == Data((0..<8192).map { UInt8($0 % 251) }) else {
            throw Failure.oracle("literal-payload-bytes-differ")
          }
        }
      }
    } catch { await reader.reset(); throw error }
    await reader.reset()
  }

  private func planner(count: Int, zones pair: [CloudZoneID]) async throws {
    try await budget.perform("planner-with-setup", seconds: 180) { try await self.executePlanner(count: count, zones: pair) }
  }
  private func executePlanner(count: Int, zones pair: [CloudZoneID]) async throws {
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "maintainer-contract",
      generation: UUID(), zones: Set(pair))
    let library = try SwiftDataSnipLibrary(storeURL: evidence.directory.appendingPathComponent("planner\(count)/store"))
    let urls = try (0..<count).map { index in
      let url = evidence.directory.appendingPathComponent("planner-\(count)-\(index).txt")
      try Data("planner original bytes \(index)".utf8).write(to: url); return url
    }
    let update = try await library.perform(.add(content: "planner fixture", origin: .quickEntry, source: nil,
      listID: SnipList.inbox.id, attachmentURLs: urls, requestID: UUID(), now: Date(timeIntervalSince1970: 1)), sortedBy: .manual)
    guard case .add(.added(let snipID)) = update.outcome else { throw Failure.oracle("planner-snip-missing") }
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: pair[0], payloadZone: pair[1],
      diagnostics: AppDiagnosticRecorder(record: { _ in }))
    try await store.approveEnrollment(references: [.init(kind: .list, domainID: SnipList.inbox.id), .init(kind: .snip, domainID: snipID)])
    let transport = Self.transport(database, namespace: namespace, evidence: evidence, client: "planner-\(count)", fetchedZones: [pair[0]])
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport, fetchScope: .zones([pair[0]]),
      diagnostics: AppDiagnosticRecorder(record: { _ in }))
    do {
      try await phase("setup-planner-\(count)") {
        try await Self.preparePlanner(coordinator, transport: transport, zones: Set(pair), validate: {
          try self.budget.check("planner-boundary")
          try await self.validateAccount()
        })
        let remaining = try await store.pendingChanges()
        try Self.require(remaining.operations.isEmpty, "planner-bootstrap-not-settled")
      }
      let before = try await library.checkedSnapshot(sortedBy: .manual)
      guard let snip = before.snips.first(where: { $0.id == snipID }), snip.attachments.count == count else {
        throw Failure.oracle("planner-attachment-precondition")
      }
      let published = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey).publications
        .filter { $0.metadata.snipID == snipID }
      let expectedIDs = Set(published.map { CloudAttachmentRecordCodec.recordID($0.metadataIdentity) })
      try Self.require(published.count == count && published.allSatisfy { $0.metadataAccepted && $0.payloadAccepted },
        "planner-bootstrap-acknowledgements-missing")
      let expectedOrder = [1, 0] + Array(2..<count)
      _ = try await library.perform(.editAttachments(snipID: snipID, content: snip.content,
        edits: expectedOrder.map { .existing(attachmentID: snip.attachments[$0].id) },
        expectedUpdatedAt: snip.updatedAt, now: Date(timeIntervalSince1970: 2)), sortedBy: .manual)
      try await phase("10-planner-\(count)") {
        let plan = try await store.pendingChanges()
        let metadata = plan.operations.compactMap { operation -> CloudRecordDraft? in
          guard case .save(let draft) = operation, draft.recordType == CloudAttachmentRecordCodec.metadataRecordType else { return nil }
          return draft
        }
        try Self.require(metadata.count == count && plan.operations.count == count && plan.zonesToSave.isEmpty,
          "planner-member-save-count-or-unexpected-ordinary-work")
        try Self.require(Set(metadata.map(\.id)) == expectedIDs && metadata.allSatisfy { $0.base != nil },
          "planner-reorder-changed-published-identities")
        let groups = CloudAttachmentOrderWrite.groups(in: plan.operations)
        try Self.require(groups.count == 1 && groups[snipID]?.count == count, "planner-logical-group-count")
        try await Self.sendPlanner(coordinator, validate: {
          try self.budget.check("planner-boundary")
          try await self.validateAccount()
        })
        let trace = try self.evidence.entries(phase: "10-planner-\(count)", client: "planner-\(count)")
        let batches = trace.filter { $0.kind == "provider-batch" }
        try Self.require(batches.count == 1 && batches[0].atomic == true
          && Set(batches[0].ids) == Set(metadata.map { self.evidence.name(CloudKitRecordMapper.recordID(for: $0.id)) }),
          "planner-provider-logical-cost")
        try Self.eventsMatchBatches(trace)
        try Self.require(trace.filter { $0.kind == "sent-event-before" }.allSatisfy { $0.errors.isEmpty },
          "planner-terminal-failure-or-retry")
        try Self.require(try await store.pendingChanges().operations.isEmpty, "planner-reorder-not-settled")
        let fetched = try await self.database.records(for: metadata.map { CloudKitRecordMapper.recordID(for: $0.id) }, desiredKeys: nil)
        for index in 0..<count {
          let originalID = snip.attachments[index].id.uuidString.lowercased()
          let records = try fetched.values.map { try CloudKitRecordMapper.snapshot($0.get()) }
          guard let record = records.first(where: { $0.encryptedFields["attachmentID"] == .string(originalID) }) else {
            throw Failure.oracle("planner-server-member-missing")
          }
          try Self.require(record.encryptedFields["position"] == .int64(Int64(expectedOrder.firstIndex(of: index)!))
            && record.encryptedFields["fileName"] == .string("planner-\(count)-\(index).txt")
            && record.encryptedFields["contentType"] == .string("public.plain-text")
            && record.encryptedFields["byteCount"] == .int64(Int64(Data("planner original bytes \(index)".utf8).count))
            && record.encryptedFields["sha256"] == .data(Data("planner original bytes \(index)".utf8).sha256ForContract), "planner-literal-server-values")
          let identity = try CloudAttachmentRecordCodec.metadata(from: record).payloadIdentity
          let target = self.evidence.directory.appendingPathComponent("planner-download-\(UUID().uuidString)")
          try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
          defer { try? FileManager.default.removeItem(at: target) }
          guard let receipt = try await transport.fetchAsset(CloudAttachmentRecordCodec.recordID(identity),
            field: CloudAttachmentRecordCodec.assetField, destination: CloudAssetDestination(validating: target)),
            try Data(contentsOf: receipt.fileURL) == Data("planner original bytes \(index)".utf8) else {
            throw Failure.oracle("planner-original-payload-bytes-differ")
          }
        }
        self.manifest.withLock { $0.results["10-cost-\(count)"] = "atomic-provider-batches=\(batches.count); metadata-member-saves=\(metadata.count); all-provider-batches=\(batches.count); successful-metadata-saves=\(trace.filter { $0.kind == "sent-event-before" }.flatMap(\.ids).count); provider-calls=\(trace.filter { $0.kind.hasPrefix("provider-") }.count); logical-not-HTTP" }
      }
    } catch { await transport.reset(); throw error }
    await transport.reset()
  }
}

private extension Data {
  var sha256ForContract: Data { Data(SHA256.hash(data: self)) }
}
#endif
