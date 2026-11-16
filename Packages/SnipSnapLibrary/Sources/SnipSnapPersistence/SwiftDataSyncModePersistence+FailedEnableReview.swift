import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  func failedEnableSetupReviewSnapshot() throws -> FailedEnableSetupReviewSnapshot {
    let sourceID = manifest.activeStoreID
    do {
      guard let bundle = try failedEnableFiles.read(sourceID) else {
        return FailedEnableSetupReviewSnapshot(sourceStoreID: sourceID, issues: [])
      }
      var issueIDs: Set<UUID> = []
      let issues = try bundle.namespaces.flatMap(\.reviews).map { review in
        let id = try FailedEnableEncoding.uuid(review.id)
        let reference = try review.reference.domain
        guard issueIDs.insert(id).inserted,
          review.local.sourceStoreID == FailedEnableEncoding.uuid(sourceID),
          let reason = FailedEnableSetupReviewReason(rawValue: review.reason.rawValue)
        else { throw FailedEnableSetupReviewReadError.evidenceUnavailable }
        let entityID: FailedEnableSetupEntityID = switch reference.kind {
        case .snip: .snip(reference.domainID)
        case .list: .list(reference.domainID)
        }
        let local: FailedEnableSetupLocalVersion?
        if let image = review.local.image.value {
          guard image.reference == review.reference else {
            throw FailedEnableSetupReviewReadError.evidenceUnavailable
          }
          try image.validate(blobs: bundle.blobs)
          switch image {
          case .snip(let snip): local = .snip(try snip.domain)
          case .list(let list): local = .list(try list.domain)
          }
        } else {
          local = nil
        }
        return FailedEnableSetupIssue(id: id, entityID: entityID,
          reason: reason, localVersionAtReview: local)
      }
      return FailedEnableSetupReviewSnapshot(sourceStoreID: sourceID,
        issues: issues.sorted { $0.id.uuidString < $1.id.uuidString })
    } catch {
      throw FailedEnableSetupReviewReadError.evidenceUnavailable
    }
  }
}
