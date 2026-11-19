import Foundation
import SnipSnapPersistence

struct CloudSetupDeleteProtection: Sendable {
  private let receiptsByPointer: [CloudTextStorageIdentity: [CloudSetupPointerDelete]]
  let payloads: Set<CloudTextStorageIdentity>
  let allowsFreshLocalRemoval: Bool

  init(_ receipts: [CloudSetupPointerDelete] = [], allowsFreshLocalRemoval: Bool = false) {
    receiptsByPointer = Dictionary(grouping: receipts, by: \.key.pointer)
    payloads = Set(receipts.flatMap(\.payloadIdentities))
    self.allowsFreshLocalRemoval = allowsFreshLocalRemoval
  }

  func blocksSetupOperation(_ operation: CloudOutboundOperation) -> Bool {
    let identity = CloudFullSyncPersistence.storageIdentity(operation.id)
    if case .delete = operation, receiptsByPointer[identity] != nil { return true }
    return payloads.contains(identity)
  }

  func blocksPointerRemoval(
    _ publication: CloudAttachmentPublication, dataZone: CloudZoneID, payloadZone: CloudZoneID
  ) -> Bool {
    guard let originalReceipts = receiptsByPointer[publication.metadataIdentity] else { return false }
    guard allowsFreshLocalRemoval, publication.isFirstLocalRemovalOfFetchedPublication,
      !payloads.contains(publication.metadata.payloadIdentity),
      let current = checkedPointer(publication.metadataShadowData, identity: publication.metadataIdentity,
        dataZone: dataZone, payloadZone: payloadZone),
      current == publication.metadata
    else { return true }
    return originalReceipts.contains { receipt in
      guard let original = checkedPointer(receipt.originalMetadataShadow, identity: receipt.key.pointer,
        dataZone: dataZone, payloadZone: payloadZone)
      else { return true }
      return current.payloadIdentity == original.payloadIdentity
    }
  }

  private func checkedPointer(
    _ data: Data?, identity: CloudTextStorageIdentity, dataZone: CloudZoneID, payloadZone: CloudZoneID
  ) -> CloudAttachmentMetadataValue? {
    guard let data, let shadow = try? CloudRecordShadow(data: data),
      let record = try? CloudKitRecordMapper.snapshot(shadow.record()),
      CloudFullSyncPersistence.storageIdentity(record.id) == identity
    else { return nil }
    return try? CloudAttachmentRecordCodec.metadata(from: record, metadataZone: dataZone, payloadZone: payloadZone)
  }
}
