import Foundation
import SnipSnapPersistence

/// Corrupt-shadow recovery for one stored snapshot: each valid archived revision moves
/// archived → recovering → resolved, one store commit per move
/// (`quarantineCorruptCloudEntities`, `beginCorruptCloudShadowRecovery`,
/// `resolveCorruptCloudShadows`). Rows that belong to no valid revision, such as invalid
/// archives, orphan or mismatched attempts, and other quarantines, only need attention.
struct CloudCorruptShadowRecovery: Sendable {
  private enum Stage: Equatable, Sendable {
    /// No exact recovery attempt; a fetch must not apply the record without a bound base.
    case archived
    /// The archive and its exact attempt wait for a clean first fetch.
    case recovering
    /// Only the resolution marker remains. Kept so the marker reads as resolved, not as a
    /// row that needs attention.
    case resolved
  }

  private struct Revision: Sendable {
    let row: CloudStoredQuarantine
    let stage: Stage
  }

  private let revisions: [Revision]
  private let hasUnclassifiedRows: Bool

  init(_ rows: [CloudStoredQuarantine], dataZone: CloudZoneID) {
    func isValid(_ row: CloudStoredQuarantine) -> Bool {
      CloudFullSyncPersistence.isValidCorruptShadowRevision(row, dataZone: dataZone)
    }
    var archives: [CloudStoredQuarantine] = []
    var attempts: [String: CloudStoredQuarantine] = [:]
    var resolutions: [CloudStoredQuarantine] = []
    var unclassifiedCount = 0
    for row in rows {
      switch row.corruptShadowMarker {
      case .archive where isValid(row): archives.append(row)
      case .recoveryAttempt: attempts[row.corruptShadowArchiveKey] = row
      case .resolution where isValid(row): resolutions.append(row)
      default: unclassifiedCount += 1
      }
    }
    var pairedAttempts = 0
    var revisions = archives.map { archive -> Revision in
      guard let attempt = attempts[archive.key], attempt.reference == archive.reference,
        attempt.identity == archive.identity, attempt.payload == archive.payload
      else { return Revision(row: archive, stage: .archived) }
      pairedAttempts += 1
      return Revision(row: archive, stage: .recovering)
    }
    // A resolution marker beside its own archive (an older build archived it again) adds
    // nothing; the archive decides the stage.
    let archiveKeys = Set(archives.map(\.key))
    revisions += resolutions.filter { !archiveKeys.contains($0.corruptShadowArchiveKey) }
      .map { Revision(row: $0, stage: .resolved) }
    self.revisions = revisions
    hasUnclassifiedRows = unclassifiedCount > 0 || attempts.count > pairedAttempts
  }

  /// Archived and recovering revisions, in row order. Their records stay withheld.
  var unresolvedArchives: [CloudStoredQuarantine] {
    revisions.filter { $0.stage != .resolved }.map(\.row)
  }

  /// The archives a clean first fetch resolves.
  var recoveringArchives: [CloudStoredQuarantine] {
    revisions.filter { $0.stage == .recovering }.map(\.row)
  }

  var needsRecovery: Bool { revisions.contains { $0.stage != .resolved } }

  var needsAttention: Bool { needsRecovery || hasUnclassifiedRows }

  var blockedRecordIDs: Set<CloudRecordID> {
    Set(unresolvedArchives.map { CloudFullSyncPersistence.recordID($0.identity) })
  }

  var blockedReferences: Set<CloudEntityReference> { Set(unresolvedArchives.map(\.reference)) }

  var unpreparedRecordIDs: Set<CloudRecordID> {
    Set(revisions.filter { $0.stage == .archived }
      .map { CloudFullSyncPersistence.recordID($0.row.identity) })
  }
}
