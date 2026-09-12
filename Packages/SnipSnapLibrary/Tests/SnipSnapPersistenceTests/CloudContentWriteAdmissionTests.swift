import Foundation
import SwiftData
import XCTest
import SnipSnapCore
@testable import SnipSnapPersistence

final class CloudContentWriteAdmissionTests: XCTestCase {
  private let namespace = "content-admission-namespace"

  func testMalformedStagedEvidenceRefusesEditsAndImportsBeforeAndAfterReopen() async throws {
    let id = UUID()
    let batch = fullBatch(id: id)
    let payload = try JSONEncoder().encode(batch)
    let envelope = try wrapped(payload)
    let cases: [(String, Evidence)] = [
      ("unreadable bytes", .staged(id, Data([0xff]))),
      ("unreadable full payload", .staged(id, try wrapped(Data([0xff])))),
      ("unknown format", .staged(id, try changed(envelope, key: "format", value: "futureRecords"))),
      ("unknown envelope version", .staged(id, try changed(envelope, key: "storageVersion", value: 2))),
      ("damaged envelope marker", .staged(id, try changed(envelope, key: "marker", value: "damaged"))),
      ("unknown batch version", .staged(id, try wrapped(changed(payload, key: "storageVersion", value: 2)))),
      ("different namespace", .staged(id, try wrapped(changed(payload, key: "namespaceKey", value: "another")))),
      ("different batch ID", .staged(UUID(), envelope)),
      ("damaged stored key", .staged(id, envelope, "wrong-key")),
      ("invalid wrapped legacy", .staged(id, try wrapped(Data([0xff]), format: .legacyTextV1))),
      ("full payload labeled legacy", .staged(id, try wrapped(payload, format: .legacyTextV1))),
    ]
    for (label, evidence) in cases { try await verify(evidence, error: .invalidStore, label: label) }
  }

  func testMalformedFullRecoveryEvidenceRefusesEditsAndImportsBeforeAndAfterReopen() async throws {
    let id = UUID()
    let payload = try JSONEncoder().encode(recovery(id: id, kind: .destructiveReset))
    let envelope = try wrapped(payload)
    let key = recoveryKey(id)
    let cases: [(String, Evidence)] = [
      ("unreadable bytes", .recovery(key, Data([0xff]))),
      ("unreadable full payload", .recovery(key, try wrapped(Data([0xff])))),
      ("unknown format", .recovery(key, try changed(envelope, key: "format", value: "futureRecords"))),
      ("unknown envelope version", .recovery(key, try changed(envelope, key: "storageVersion", value: 2))),
      ("unknown recovery version", .recovery(key, try wrapped(changed(payload, key: "storageVersion", value: 2)))),
      ("different namespace", .recovery(key, try wrapped(changed(payload, key: "namespaceKey", value: "another")))),
      ("different batch ID", .recovery(recoveryKey(UUID()), envelope)),
      ("different event kind", .recovery("unexpected-event", envelope)),
      ("reset mislabeled as review", .recovery("review-recovery-\(id.uuidString.lowercased())", envelope)),
      ("damaged stored key", .recovery(key, envelope, "wrong-key")),
      ("unknown recovery kind", .recovery(key, try wrapped(changed(payload, key: "kind", value: "futureReset")))),
      ("reset labeled legacy", .recovery(key, try wrapped(payload, format: .legacyTextV1))),
    ]
    for (label, evidence) in cases { try await verify(evidence, error: .invalidStore, label: label) }
  }

  func testStagedRecoveryInputsAndChangesMustMatchTheirStoredIdentity() async throws {
    let id = UUID()
    let input = try recovery(id: id, kind: .destructiveReset)
    let encoded = try JSONEncoder().encode(input)
    for (key, value) in [("storageVersion", 2 as Any), ("namespaceKey", "another" as Any),
      ("batchID", UUID().uuidString as Any)] {
      var batch = try json(JSONEncoder().encode(fullBatch(id: id)))
      batch["recoveryInputs"] = [try json(changed(encoded, key: key, value: value))]
      try await verify(.staged(id, try wrapped(JSONSerialization.data(withJSONObject: batch))),
        error: .invalidStore, label: "nested \(key)")
    }
    let prior = try recovery(id: UUID(), kind: .retryableFetch)
    let wrongNamespace = CloudFullRecoveryInput(namespaceKey: "another", batchID: prior.batchID,
      kind: .retryableFetch, outboundData: Data(), resultData: Data())
    for change in [
      CloudFullRecoveryChange(expected: wrongNamespace, replacement: nil),
      CloudFullRecoveryChange(expected: prior, replacement: try recovery(id: UUID(), kind: .retryableFetch)),
    ] {
      let batch = fullBatch(id: id, changes: [change])
      try await verify(.staged(id, try wrapped(JSONEncoder().encode(batch))),
        error: .invalidStore, label: "nested recovery change")
    }
  }

  func testValidResetStillRefusesWritesWithoutHidingExistingContent() async throws {
    let id = UUID()
    let input = try recovery(id: id, kind: .destructiveReset)
    let batch = fullBatch(id: id, inputs: [input])
    try await verify(.staged(id, try wrapped(JSONEncoder().encode(batch))),
      error: .modeTransitionInProgress, label: "valid staged reset")
    try await verify(.recovery(recoveryKey(id), try wrapped(JSONEncoder().encode(input))),
      error: .modeTransitionInProgress, label: "valid committed reset")
  }

  func testValidLegacyNonresetAndReviewEvidenceRemainsWritable() async throws {
    let id = UUID()
    let legacyBatch = try JSONSerialization.data(withJSONObject: ["fetched": ["_0": [
      "id": id.uuidString, "items": [], "databaseEvents": [], "zoneEvents": [],
    ]]])
    let legacyRecovery = Data("{\"modeRetryDeletion\":{}}".utf8)
    let legacyEnvelope = try wrapped(legacyRecovery, format: .legacyTextV1)
    let prior = try recovery(id: UUID(), kind: .retryableFetch)
    let review = SnipRecoveryRecord.list(RecoveredListEdit(id: UUID(), currentListID: SnipList.inbox.id,
      recovered: .inbox, conflictingFields: [.name]))
    let reviewPayload = try JSONSerialization.data(withJSONObject: [
      "storageVersion": 1, "conflictKey": "review", "recovery": try json(JSONEncoder().encode(review)),
    ])
    let cases: [(String, Evidence)] = [
      ("raw legacy batch", .staged(id, legacyBatch)),
      ("wrapped legacy batch", .staged(id, try wrapped(legacyBatch, format: .legacyTextV1))),
      ("raw legacy recovery", .recovery("\(id.uuidString.lowercased())-\(legacyRecovery.base64EncodedString())", legacyRecovery)),
      ("wrapped legacy recovery", .recovery("\(id.uuidString.lowercased())-\(legacyEnvelope.base64EncodedString())", legacyEnvelope)),
      ("nonreset staged", .staged(id, try wrapped(JSONEncoder().encode(fullBatch(id: id,
        inputs: [recovery(id: id, kind: .retryableFetch)]))))),
      ("nonreset recovery", .recovery(recoveryKey(id), try wrapped(JSONEncoder().encode(recovery(id: id, kind: .retryableFetch))))),
      ("valid recovery change", .staged(id, try wrapped(JSONEncoder().encode(fullBatch(id: id,
        changes: [CloudFullRecoveryChange(expected: prior, replacement: prior)]))))),
      ("user review", .recovery("review-recovery-\(review.id.uuidString.lowercased())", try wrapped(reviewPayload))),
    ]
    for (label, evidence) in cases { try await verify(evidence, error: nil, label: label) }
  }

  func testRawStagedResetRefusesWritesWhenOtherResetEvidenceIsMissingOrDisagrees() async throws {
    let id = UUID()
    for kind in ["fetched", "sent"] {
      for reason in ["purged", "encryptedDataReset"] {
        let raw = try rawBatch(id: id, kind: kind, reason: reason)
        for inputs in [[], [try recovery(id: id, kind: .retryableFetch)]] {
          let batch = fullBatch(id: id, inputs: inputs,
            state: CloudFullNamespaceState(revision: 1, phase: .active), raw: raw)
          var payload = try json(JSONEncoder().encode(batch))
          if inputs.isEmpty { payload.removeValue(forKey: "recoveryInputs") }
          try await verify(.staged(id, try wrapped(JSONSerialization.data(withJSONObject: payload))),
            error: .modeTransitionInProgress, label: "raw \(kind) \(reason) disagrees with recovery")
        }
      }
    }
    let blocked = fullBatch(id: id, state: CloudFullNamespaceState(revision: 1, phase: .blocked))
    try await verify(.staged(id, try wrapped(JSONEncoder().encode(blocked))),
      error: .modeTransitionInProgress, label: "blocked namespace without recovery or raw data")
    let disagreement = try fullBatch(id: id, inputs: [recovery(id: id, kind: .destructiveReset)],
      raw: try rawBatch(id: id, kind: "fetched"))
    try await verify(.staged(id, try wrapped(JSONEncoder().encode(disagreement))),
      error: .modeTransitionInProgress, label: "reset recovery disagrees with raw success")
  }

  func testPresentRawStagedEvidenceMustHaveKnownVersionBatchIdentityAndResetEvents() async throws {
    let id = UUID()
    let raw = try rawBatch(id: id, kind: "fetched")
    let cases: [(String, Data)] = [
      ("unreadable raw data", Data([0xff])),
      ("unknown raw version", try changed(raw, key: "storageVersion", value: 2)),
      ("invalid raw version type", try changed(raw, key: "storageVersion", value: true)),
      ("missing raw version", Data("{}".utf8)),
      ("missing wire batch", Data("{\"storageVersion\":1}".utf8)),
      ("unknown wire batch kind", try changed(raw, key: "batch", value: ["futureFetch": [:]])),
      ("different wire batch ID", try rawBatch(id: UUID(), kind: "fetched")),
      ("missing wire batch headers", try changed(raw, key: "batch", value: ["fetched": ["_0": ["id": id.uuidString]]])),
      ("unknown reset reason", try rawBatch(id: id, kind: "sent", reason: "futureReset")),
      ("missing reset reason", try rawBatch(id: id, kind: "fetched", event: ["zoneDeleted": ["_0": ["name": "text", "ownerName": "owner"]]])),
      ("unknown database event", try rawBatch(id: id, kind: "fetched", event: ["futureReset": [:]])),
      ("malformed database event", try rawBatch(id: id, kind: "fetched", event: ["zoneDeleted": "purged"])),
    ]
    for (label, raw) in cases {
      try await verify(.staged(id, try wrapped(JSONEncoder().encode(fullBatch(id: id, raw: raw)))),
        error: .invalidStore, label: label)
    }
    let state = CloudFullNamespaceState(revision: 1, phase: .active)
    let unknownState = try changed(JSONEncoder().encode(state), key: "storageVersion", value: 2)
    let batch = try changed(JSONEncoder().encode(fullBatch(id: id)), key: "nextNamespaceState", value: json(unknownState))
    try await verify(.staged(id, try wrapped(batch)), error: .invalidStore, label: "unknown namespace state version")
  }

  func testNonresetRawAndOlderRawlessFullCommitsRemainWritable() async throws {
    let id = UUID()
    for kind in ["fetched", "sent"] {
      let batch = fullBatch(id: id, state: CloudFullNamespaceState(revision: 1, phase: .active),
        raw: try rawBatch(id: id, kind: kind, reason: "deleted"))
      try await verify(.staged(id, try wrapped(JSONEncoder().encode(batch))), error: nil,
        label: "nonreset raw \(kind)")
    }
    // Lower-level storage commits predate the optional replay and recovery fields.
    let minimal: [String: Any] = ["storageVersion": 1, "namespaceKey": namespace,
      "batchID": id.uuidString, "items": []]
    try await verify(.staged(id, try wrapped(JSONSerialization.data(withJSONObject: minimal))),
      error: nil, label: "older rawless full commit")
  }

  func testFetchAndSendRecoveryRequiresMatchingReadableRawEvidence() async throws {
    let id = UUID()
    for kind: CloudFullRecoveryKind in [.retryableFetch, .terminalFetch, .retryableSend, .terminalSend] {
      let family = kind == .retryableFetch || kind == .terminalFetch ? "fetched" : "sent"
      let valid = try recovery(id: id, kind: kind)
      let cases: [(String, Data, SnipLibraryError?)] = [
        ("valid failure frame", valid.resultData, nil),
        ("missing raw data", Data(), .invalidStore),
        ("unreadable raw data", Data([0xff]), .invalidStore),
        ("unknown raw version", try changed(valid.resultData, key: "storageVersion", value: 2), .invalidStore),
        ("different batch ID", try rawBatch(id: UUID(), kind: family), .invalidStore),
        ("different batch family", try rawBatch(id: id, kind: family == "fetched" ? "sent" : "fetched"), .invalidStore),
        ("hidden purge", try rawBatch(id: id, kind: family, reason: "purged"), .modeTransitionInProgress),
        ("hidden encrypted reset", try rawBatch(id: id, kind: family, reason: "encryptedDataReset"), .modeTransitionInProgress),
        ("malformed reset", try rawBatch(id: id, kind: family,
          event: ["zoneDeleted": ["_0": ["name": "text", "ownerName": "owner"]]]), .invalidStore),
      ]
      for (label, raw, expected) in cases {
        let input = try recovery(id: id, kind: kind, resultData: raw)
        let evidence: [Evidence] = [
          .recovery(recoveryKey(id), try wrapped(JSONEncoder().encode(input))),
          .staged(id, try wrapped(JSONEncoder().encode(fullBatch(id: id, inputs: [input])))),
        ]
        for row in evidence {
          try await verify(row, error: expected, label: "\(kind) \(label)")
        }
      }
    }
  }

  func testCommittedBlockedNamespaceKeepsWriteRefusalAfterResetInputIsConsumed() async throws {
    let id = UUID()
    for family in ["fetched", "sent"] {
      let batch = fullBatch(id: id, state: CloudFullNamespaceState(revision: 1, phase: .blocked),
        raw: try rawBatch(id: id, kind: family, reason: "purged"))
      try await verify(.committed(batch), error: .modeTransitionInProgress,
        label: "committed \(family) reset without recovery or result delivery")
    }
    let active = fullBatch(id: id, state: CloudFullNamespaceState(revision: 1, phase: .active))
    try await verify(.committed(active), error: nil, label: "committed active namespace")
    let legacy = try JSONEncoder().encode(Set<CloudEntityReference>())
    try await verify(.enrollment(legacy), error: nil, label: "legacy enrollment set")
    try await verify(.enrollment(Data([0xff])), error: .invalidStore, label: "unreadable enrollment")
  }

  func testLegacyDatabaseResetEvidenceRefusesWritesAndPreservesOtherEvents() async throws {
    let id = UUID()
    for reason in ["deleted", "purged", "encryptedDataReset", "unknownReset"] {
      let event: [String: Any] = ["zoneDeleted": [
        "_0": ["name": "text", "ownerName": "owner"], "reason": reason,
      ]]
      let expected: SnipLibraryError? = switch reason {
      case "deleted": nil
      case "purged", "encryptedDataReset": .modeTransitionInProgress
      default: .invalidStore
      }
      let batch = try JSONSerialization.data(withJSONObject: ["fetched": ["_0": [
        "id": id.uuidString, "items": [], "databaseEvents": [event], "zoneEvents": [],
      ]]])
      let recovery = try JSONSerialization.data(withJSONObject: ["database": ["_0": event]])
      for envelope in [false, true] {
        let batchPayload = envelope ? try wrapped(batch, format: .legacyTextV1) : batch
        let recoveryPayload = envelope ? try wrapped(recovery, format: .legacyTextV1) : recovery
        try await verify(.staged(id, batchPayload), error: expected, label: "legacy staged \(reason)")
        try await verify(.recovery("\(id.uuidString.lowercased())-\(recoveryPayload.base64EncodedString())",
          recoveryPayload), error: expected, label: "legacy recovery \(reason)")
      }
    }
    let changed = try JSONSerialization.data(withJSONObject: ["database": ["_0": [
      "zoneChanged": ["_0": ["name": "text", "ownerName": "owner"]],
    ]]])
    try await verify(.recovery("\(id.uuidString.lowercased())-\(changed.base64EncodedString())", changed),
      error: nil, label: "legacy zone changed")
  }

  private func verify(_ evidence: Evidence, error expectedError: SnipLibraryError?, label: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContentAdmission-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("snips.store")
    let first = try SwiftDataSnipLibrary(storeURL: url)
    _ = try await first.perform(Self.add("saved content"), sortedBy: .manual)
    let preview = try await first.previewImport(SnipLibraryTransferSnapshot(revision: 0,
      snips: [], lists: [.inbox], attachmentData: [:], legacyManualPositions: [:]), transitionID: UUID())
    let plan = try await first.prepareTransferPlan(preview.source, transitionID: UUID(),
      replacingTargetSnipIDs: [], priorSeedProvenance: [], priorServerAcceptedSnipIDs: [], priorSeededListIDs: [])
    try await first.insertAdmissionEvidence(evidence, namespace: namespace)
    for reopened in [false, true] {
      let library = reopened ? try SwiftDataSnipLibrary(storeURL: url) : first
      let update = Self.add(reopened ? "after reopen" : "before reopen")
      if let expectedError {
        do { _ = try await library.perform(update, sortedBy: .manual); XCTFail("Accepted edit: \(label)") }
        catch { XCTAssertEqual(error as? SnipLibraryError, expectedError, label) }
        do { _ = try await library.applyTransferPlan(plan); XCTFail("Accepted import commit: \(label)") }
        catch { XCTAssertEqual(error as? SnipLibraryError, expectedError, label) }
        do { _ = try await library.applyImport(preview); XCTFail("Accepted import: \(label)") }
        catch {
          // The public import API maps an invalidStore commit to importChanged;
          // malformed legacy state can also fail earlier while preparing its plan.
          let allowed = expectedError == .invalidStore ? [.invalidStore, .importChanged] : [expectedError]
          XCTAssertTrue(allowed.contains(error as? SnipLibraryError ?? .storeUnavailable), label)
        }
      } else {
        // Preview again after each accepted edit so import checks the current content.
        _ = try await library.perform(update, sortedBy: .manual)
        let currentPreview = try await library.previewImport(preview.source, transitionID: UUID())
        _ = try await library.applyImport(currentPreview)
      }
      let snapshot = try await library.checkedSnapshot(sortedBy: .manual)
      XCTAssertTrue(snapshot.snips.contains { $0.content == "saved content" }, label)
      if expectedError != nil { XCTAssertEqual(snapshot.snips.map(\.content), ["saved content"], label) }
    }
  }

  private func fullBatch(id: UUID, inputs: [CloudFullRecoveryInput] = [],
    changes: [CloudFullRecoveryChange] = [], state: CloudFullNamespaceState? = nil,
    raw: Data? = nil) -> CloudFullBatchCommit {
    CloudFullBatchCommit(namespaceKey: namespace, batchID: id, expectedEngineState: nil,
      nextEngineState: nil, nextNamespaceState: state, rawBatchData: raw,
      recoveryInputs: inputs, recoveryChanges: changes, items: [])
  }

  private func rawBatch(id: UUID, kind: String, reason: String? = nil,
    event: [String: Any]? = nil) throws -> Data {
    let databaseEvent = event ?? reason.map { ["zoneDeleted": [
      "_0": ["name": "text", "ownerName": "owner"], "reason": $0,
    ]] }
    var raw: [String: Any] = ["storageVersion": 1, "batch": [kind: ["_0": [
      "id": id.uuidString, "items": [], "databaseEvents": databaseEvent.map { [$0] } ?? [],
      "zoneEvents": [],
    ]]]]
    if kind == "sent" { raw["outbound"] = ["operations": []] }
    return try JSONSerialization.data(withJSONObject: raw)
  }

  private func recovery(id: UUID, kind: CloudFullRecoveryKind, resultData: Data? = nil) throws -> CloudFullRecoveryInput {
    let family = kind == .retryableSend || kind == .terminalSend ? "sent" : "fetched"
    let failure = kind == .terminalFetch || kind == .terminalSend ? "quotaExceeded" : "networkUnavailable"
    let raw = try resultData ?? rawBatch(id: id, kind: family,
      event: ["failed": ["_0": ["name": "text", "ownerName": "owner"], "_1": failure]])
    return CloudFullRecoveryInput(namespaceKey: namespace, batchID: id, kind: kind,
      outboundData: family == "sent" ? try JSONSerialization.data(withJSONObject: ["operations": []]) : Data(),
      resultData: raw)
  }

  private func recoveryKey(_ id: UUID) -> String { "full-recovery-\(id.uuidString.lowercased())" }
  private func wrapped(_ data: Data, format: CloudWirePayloadFormat = .fullRecordV1) throws -> Data {
    try CloudWirePayloadEnvelope(format: format, payload: data).encoded()
  }
  private func json(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
  private func changed(_ data: Data, key: String, value: Any) throws -> Data {
    var object = try json(data)
    object[key] = value
    return try JSONSerialization.data(withJSONObject: object)
  }
  private static func add(_ content: String) -> SnipLibraryCommand {
    .add(content: content, origin: .quickEntry, source: nil, listID: SnipList.inbox.id,
      attachmentURLs: [], requestID: UUID(), now: Date())
  }
}

private enum Evidence: Sendable {
  case staged(UUID, Data, String? = nil)
  case recovery(String, Data, String? = nil)
  case committed(CloudFullBatchCommit)
  case enrollment(Data)
}

private extension SwiftDataSnipLibrary {
  func insertAdmissionEvidence(_ evidence: Evidence, namespace: String) throws {
    let context = Self.makeContext(container: try XCTUnwrap(container))
    switch evidence {
    case .staged(let id, let payload, let storedID):
      let row = StoredCloudStagedBatch(namespaceKey: namespace, batchID: id, payload: payload)
      if let storedID { row.id = storedID }
      context.insert(row)
    case .recovery(let key, let payload, let storedID):
      let row = StoredCloudRecoveryEvent(namespaceKey: namespace, eventKey: key, payload: payload)
      if let storedID { row.id = storedID }
      context.insert(row)
    case .committed(let batch):
      try stageCloudFullBatch(batch)
      _ = try commitCloudFullBatch(batch)
      // No callback follows this commit. Its persisted namespace is the only
      // evidence left to guard edits if the process exits or delivery fails.
      let committed = Self.makeContext(container: try XCTUnwrap(container))
      XCTAssertTrue(try committed.fetch(FetchDescriptor<StoredCloudStagedBatch>()).isEmpty)
      XCTAssertTrue(try committed.fetch(FetchDescriptor<StoredCloudRecoveryEvent>()).isEmpty)
      return
    case .enrollment(let payload):
      context.insert(StoredCloudFullEnrollment(namespaceKey: namespace, referencesData: payload))
    }
    try context.save()
  }
}
