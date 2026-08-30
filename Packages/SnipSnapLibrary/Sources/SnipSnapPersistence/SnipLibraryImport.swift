import Foundation
import SnipSnapCore

public enum SnipLibraryImport {
  public static func preview(
    source: any SnipLibrary,
    target: any SnipLibrary
  ) async throws -> SnipImportPreview {
    let transitionID = UUID()
    let sourceSnapshot = try await source.previewTransferSnapshot(revision: 0)
    let staged = try AttachmentFileIO.stagePreviewSnapshot(
      sourceSnapshot,
      transitionID: transitionID
    )
    do {
      return try await target.previewImport(
        staged.snapshot,
        transitionID: transitionID
      ).withOptionalStagingLease(staged.lease)
    } catch {
      try? staged.lease?.release()
      throw error
    }
  }

  public static func preview(
    backupURL: URL,
    target: any SnipLibrary
  ) async throws -> SnipImportPreview {
    let transitionID = UUID()
    let staged = try JSONSnipArchiveTransfer.stageForImport(
      from: backupURL,
      transitionID: transitionID
    )
    do {
      let source = SnipLibraryTransferSnapshot(
        revision: 0,
        snips: staged.archive.snips,
        lists: staged.archive.lists,
        attachmentData: [:],
        attachmentFileURLs: staged.archive.attachmentURLs,
        attachmentFileDigests: staged.attachmentDigests,
        legacyManualPositions: [:]
      )
      return try await target.previewImport(source, transitionID: transitionID)
        .withStagingLease(staged.lease)
    } catch {
      try? staged.lease.release()
      throw error
    }
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
    let target = try await previewTransferSnapshot(revision: 0)
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
    let target = try await previewTransferSnapshot(revision: 0)
    let plan = try await prepareTransferPlan(
      source,
      transitionID: transitionID,
      replacingTargetSnipIDs: [],
      priorSeedProvenance: [],
      priorServerAcceptedSnipIDs: [],
      priorSeededListIDs: [],
      targetSnapshot: target
    )
    return SnipLibraryImport.makePreview(
      source: source,
      target: target,
      plan: plan,
      transitionID: transitionID
    )
  }

  public func applyImport(_ preview: SnipImportPreview) async throws -> SnipImportResult {
    try await SnipLibraryImport.applyPrepared(
      preview,
      to: self,
      beforeCommit: beforeImportCommit
    )
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
      targetDigest: plan.targetDigest,
      devicePatch: .between(
        SnipLibrarySnapshot(snips: target.snips, lists: target.lists),
        SnipLibrarySnapshot(snips: plan.snips, lists: plan.lists)
      )
    )
  }

  fileprivate static func applyPrepared(
    _ preview: SnipImportPreview,
    to target: any SnipLibrary,
    beforeCommit: @escaping @Sendable () async throws -> Void = {}
  ) async throws -> SnipImportResult {
    defer { try? preview.stagingLease?.release() }
    let current = try await target.transferSnapshot(revision: 0)
    guard SnipLibraryTransferPlanner.digest(snapshot: current) == preview.targetDigest else {
      throw SnipLibraryError.importChanged
    }
    try await beforeCommit()
    let transfer = try await target.mergeTransferSnapshot(
      preview.source,
      transitionID: preview.transitionID,
      expectedTargetDigest: preview.targetDigest
    )
    return SnipImportResult(
      snapshot: try await target.checkedSnapshot(sortedBy: .chronological),
      addedSnipCount: preview.addedSnipCount,
      recoveredSnipCount: transfer.recoveredSourceSnipIDs.count,
      devicePatch: preview.devicePatch
    )
  }
}

private extension SnipImportPreview {
  func withOptionalStagingLease(_ lease: SnipImportStagingLease?) -> Self {
    guard let lease else { return self }
    return withStagingLease(lease)
  }
}
