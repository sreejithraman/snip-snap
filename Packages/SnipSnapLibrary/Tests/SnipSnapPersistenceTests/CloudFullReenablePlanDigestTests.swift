import Foundation
import XCTest

@testable import SnipSnapCore
@testable import SnipSnapPersistence

/// A staged full re-enable plan must restore with the digest it was staged with, whatever order
/// its sets and attachment map iterate in (SM23-F2-D1).
final class CloudFullReenablePlanDigestTests: XCTestCase {
  func testPlanWithManyApprovedAndRecoveredSnipsRestoresFromItsStagedForm() throws {
    let plan = try makePlan(
      approved: Set((0..<8).map { _ in UUID() }),
      recovered: Set((0..<2).map { _ in UUID() })
    )

    let restored = try stageAndRestore(plan)

    XCTAssertNil(restored.acceptedLegacyDigest)
    XCTAssertEqual(restored.plan, plan)
    XCTAssertTrue(try restored.plan.hasValidDigest())
  }

  func testPlanWithManyAttachmentsRestoresFromItsStagedForm() throws {
    let attachments = Dictionary(uniqueKeysWithValues: (0..<6).map {
      (UUID(), Data("attachment \($0)".utf8))
    })
    let plan = try makePlan(approved: [UUID()], attachmentData: attachments)

    let restored = try stageAndRestore(plan)

    XCTAssertNil(restored.acceptedLegacyDigest)
    XCTAssertEqual(restored.plan, plan)
    XCTAssertTrue(try restored.plan.hasValidDigest())
  }

  /// A plan with at most one ID and one attachment keeps the digest it had before sets and the
  /// attachment map were sorted, so digests already stored still match.
  func testSingleEntryPlanDigestKeepsItsBytes() throws {
    // The constant is the SHA-256 of DigestInput's JSON: `.sortedKeys`, no whitespace, Data in
    // base64, UUIDs uppercase, and `[UUID: Data]` as alternating IDs and bytes:
    // {"acceptedCAS":[],
    //  "approvedSnipIDs":["5A1B0000-0000-4000-8000-000000000002"],
    //  "attachmentData":["A7AC0000-0000-4000-8000-000000000003","YXR0YWNobWVudA=="],
    //  "conflicts":[],"dormantPayload":"ZG9ybWFudA==","expectedNamespaceRevision":3,
    //  "lists":[],"namespaceKey":"pin-namespace","recoveredSourceSnipIDs":[],
    //  "recoveryInputs":[],"snips":[],"storageVersion":1,"targetDigest":"dGFyZ2V0",
    //  "targetRevision":7,"transitionID":"7A1E0000-0000-4000-8000-000000000001"}
    let transitionID = try XCTUnwrap(UUID(uuidString: "7A1E0000-0000-4000-8000-000000000001"))
    let snipID = try XCTUnwrap(UUID(uuidString: "5A1B0000-0000-4000-8000-000000000002"))
    let attachmentID = try XCTUnwrap(UUID(uuidString: "A7AC0000-0000-4000-8000-000000000003"))
    let plan = try CloudFullReenableApplyPlan(
      transitionID: transitionID,
      namespaceKey: "pin-namespace",
      expectedNamespaceRevision: 3,
      targetRevision: 7,
      targetDigest: Data("target".utf8),
      snips: [],
      lists: [],
      attachmentData: [attachmentID: Data("attachment".utf8)],
      dormantPayload: Data("dormant".utf8),
      acceptedCAS: [],
      conflicts: [],
      recoveryInputs: [],
      result: SnipLibraryTransferResult(approvedSnipIDs: [snipID], recoveredSourceSnipIDs: [])
    )

    XCTAssertEqual(
      plan.planDigest.map { String(format: "%02x", $0) }.joined(),
      "f52dbcb2aee4d856502f05feccde12062ec1ce73eaca5b1ab8728fb573c08773"
    )
  }

  private func makePlan(
    approved: Set<UUID>,
    recovered: Set<UUID> = [],
    attachmentData: [UUID: Data] = [:]
  ) throws -> CloudFullReenableApplyPlan {
    try CloudFullReenableApplyPlan(
      transitionID: UUID(),
      namespaceKey: "digest-tests",
      targetRevision: 1,
      targetDigest: Data("target".utf8),
      snips: [],
      lists: [],
      attachmentData: attachmentData,
      dormantPayload: Data("dormant".utf8),
      acceptedCAS: [],
      conflicts: [],
      recoveryInputs: [],
      result: SnipLibraryTransferResult(
        approvedSnipIDs: approved,
        recoveredSourceSnipIDs: recovered
      )
    )
  }

  /// Writes `plan` as `stageFullReenablePlan` does, then reads it back as the reconcile does.
  private func stageAndRestore(
    _ plan: CloudFullReenableApplyPlan
  ) throws -> CloudFullReenableStagedPlan.Restored {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullReenablePlanDigestTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let staged = CloudFullReenableStagedPlan(plan: plan)
    for file in staged.attachmentFiles {
      let url = root.appendingPathComponent(file.relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try XCTUnwrap(plan.attachmentData[file.id]).write(to: url)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let planURL = root.appendingPathComponent("plan.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(staged).write(to: planURL)
    let decoded = try JSONDecoder().decode(
      CloudFullReenableStagedPlan.self,
      from: Data(contentsOf: planURL)
    )
    return try decoded.restore(from: root)
  }
}
