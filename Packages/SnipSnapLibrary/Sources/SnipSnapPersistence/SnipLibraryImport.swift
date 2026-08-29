import Foundation
import SnipSnapCore

public enum SnipLibraryImport {
  public static func preview(
    source: any SnipLibrary,
    target: any SnipLibrary
  ) async throws -> SnipImportPreview {
    let sourceSnapshot = try await source.transferSnapshot(revision: 0)
    return try await target.previewImport(sourceSnapshot, transitionID: UUID())
  }

  public static func preview(
    backupURL: URL,
    target: any SnipLibrary
  ) async throws -> SnipImportPreview {
    try await preview(source: JSONSnipLibrary(fileURL: backupURL), target: target)
  }

  public static func apply(
    _ preview: SnipImportPreview,
    to target: any SnipLibrary
  ) async throws -> SnipImportResult {
    try await target.applyImport(preview)
  }
}

extension JSONSnipLibrary {
  public func previewImport(
    _ source: SnipLibraryTransferSnapshot,
    transitionID: UUID
  ) async throws -> SnipImportPreview {
    let target = try await transferSnapshot(revision: 0)
    let plan = try SnipLibraryTransferPlanner.plan(
      source: source,
      target: target,
      transitionID: transitionID
    )
    return SnipLibraryImport.makePreview(
      source: source,
      target: target,
      plan: plan,
      transitionID: transitionID
    )
  }

  public func applyImport(_ preview: SnipImportPreview) async throws -> SnipImportResult {
    try await SnipLibraryImport.applyPrepared(preview, to: self)
  }
}

extension SwiftDataSnipLibrary {
  public func previewImport(
    _ source: SnipLibraryTransferSnapshot,
    transitionID: UUID
  ) async throws -> SnipImportPreview {
    let target = try await transferSnapshot(revision: 0)
    let plan = try await prepareTransferPlan(
      source,
      transitionID: transitionID,
      replacingTargetSnipIDs: [],
      priorSeedProvenance: [],
      priorServerAcceptedSnipIDs: [],
      priorSeededListIDs: []
    )
    return SnipLibraryImport.makePreview(
      source: source,
      target: target,
      plan: plan,
      transitionID: transitionID
    )
  }

  public func applyImport(_ preview: SnipImportPreview) async throws -> SnipImportResult {
    try await SnipLibraryImport.applyPrepared(preview, to: self)
  }
}

extension SnipLibraryImport {
  fileprivate static func makePreview(
    source: SnipLibraryTransferSnapshot,
    target: SnipLibraryTransferSnapshot,
    plan: SnipLibraryTransferPlan,
    transitionID: UUID
  ) -> SnipImportPreview {
    let targetSnipIDs = Set(target.snips.map(\.id))
    let targetListIDs = Set(target.lists.map(\.id))
    let targetAttachmentIDs = Set(target.snips.flatMap(\.attachments).map(\.id))
    return SnipImportPreview(
      totalSnipCount: source.snips.count,
      addedSnipCount: source.snips.count { !targetSnipIDs.contains($0.id) },
      recoveredSnipCount: plan.result.recoveredSourceSnipIDs.count,
      addedListCount: source.lists.count { !targetListIDs.contains($0.id) },
      addedAttachmentCount: source.snips.flatMap(\.attachments).count {
        !targetAttachmentIDs.contains($0.id)
      },
      transitionID: transitionID,
      source: source,
      targetDigest: plan.targetDigest
    )
  }

  fileprivate static func applyPrepared(
    _ preview: SnipImportPreview,
    to target: any SnipLibrary
  ) async throws -> SnipImportResult {
    let current = try await target.transferSnapshot(revision: 0)
    guard SnipLibraryTransferPlanner.digest(snapshot: current) == preview.targetDigest else {
      throw SnipLibraryError.importChanged
    }
    let transfer = try await target.mergeTransferSnapshot(
      preview.source,
      transitionID: preview.transitionID
    )
    return SnipImportResult(
      snapshot: try await target.checkedSnapshot(sortedBy: .chronological),
      addedSnipCount: preview.addedSnipCount,
      recoveredSnipCount: transfer.recoveredSourceSnipIDs.count
    )
  }
}
