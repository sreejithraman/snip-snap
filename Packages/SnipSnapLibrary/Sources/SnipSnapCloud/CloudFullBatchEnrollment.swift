import Foundation
import SnipSnapPersistence

extension CloudFullBatchPlanner {
  /// `initialFetch` comes from the batch before corrupt-shadow recovery adjusted it. A send
  /// keeps the open attempt.
  static func nextNamespaceState(
    current: CloudFullNamespaceState,
    batch: CloudSyncBatch,
    dataZone: CloudZoneID,
    ownedZones: Set<CloudZoneID>,
    attachmentOperationIDs: Set<CloudRecordID>,
    initialFetch: CloudFullInitialFetchStep
  ) -> CloudFullNamespaceState {
    switch batch {
    case .fetched(let fetched):
      return current.committingFetch(
        fetchOutcome(fetched, dataZone: dataZone, ownedZones: ownedZones), initialFetch: initialFetch
      )
    case .sent(let sent):
      return current.committingSend(sendOutcome(
        sent, dataZone: dataZone, ownedZones: ownedZones,
        attachmentOperationIDs: attachmentOperationIDs
      ))
    }
  }

  private static func fetchOutcome(
    _ fetched: CloudFetchedBatch,
    dataZone: CloudZoneID,
    ownedZones: Set<CloudZoneID>
  ) -> CloudFullFetchOutcome {
    if fetched.databaseEvents.contains(where: isDestructiveReset) { return .destructiveReset }
    if hasMissingZone(fetched, ownedZones: ownedZones) { return .ownedZoneMissing }
    guard fetchRecoveryKind(fetched) == nil else { return .incomplete }
    let recordZones = fetched.items.compactMap { item -> CloudZoneID? in
      guard case .record(let snapshot) = item else { return nil }
      return snapshot.id.zone
    }
    let records: CloudFullFetchOutcome.Records = if recordZones.contains(dataZone) {
      .inDataZone
    } else if recordZones.isEmpty {
      .absent
    } else {
      .outsideDataZone
    }
    return .complete(records: records)
  }

  private static func sendOutcome(
    _ sent: CloudSentBatch,
    dataZone: CloudZoneID,
    ownedZones: Set<CloudZoneID>,
    attachmentOperationIDs: Set<CloudRecordID>
  ) -> CloudFullSendOutcome {
    if sent.databaseEvents.contains(where: isDestructiveReset) { return .destructiveReset }
    if hasMissingZone(sent, ownedZones: ownedZones, attachmentOperationIDs: attachmentOperationIDs) {
      return .ownedZoneMissing
    }
    return .delivered(
      needsRetry: sent.items.contains { item in
        if case .failed(_, let failure) = item { failure.isRetryable } else { false }
      },
      savedDataZone: sent.databaseEvents.contains { event in
        if case .zoneSaved(let zone) = event { zone == dataZone } else { false }
      }
    )
  }
}
