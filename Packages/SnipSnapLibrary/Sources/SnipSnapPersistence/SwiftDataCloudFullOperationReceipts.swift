import Foundation
import SwiftData

enum CloudFullReceiptOperation: Equatable {
  case committedBatch(UUID)
  case reenableTransition(UUID)

  var operationID: UUID {
    switch self {
    case .committedBatch(let id), .reenableTransition(let id): id
    }
  }

  func storageKey(namespaceKey: String) -> String {
    "\(namespaceKey)|\(storageKind)|\(operationID.uuidString.lowercased())"
  }

  func matches(_ receipt: StoredCloudFullBatchReceipt, namespaceKey: String) -> Bool {
    receipt.namespaceKey == namespaceKey
      && receipt.id == storageKey(namespaceKey: namespaceKey)
  }

  private var storageKind: String {
    switch self {
    case .committedBatch: "full-batch"
    case .reenableTransition: "full-reenable"
    }
  }
}

/// Owns replay identity, compatibility migration, and retention for full-record operations.
enum SwiftDataCloudFullOperationReceipts {
  static func isReplay(
    _ operation: CloudFullReceiptOperation,
    namespaceKey: String,
    digest: Data,
    context: ModelContext
  ) throws -> Bool {
    guard let receipt = try receipt(
      for: operation,
      namespaceKey: namespaceKey,
      context: context
    ) else { return false }
    guard receipt.digest == digest else { throw CloudFullStorageError.invalidBatchReplay }
    return true
  }

  static func digest(
    for operation: CloudFullReceiptOperation,
    namespaceKey: String,
    context: ModelContext
  ) throws -> Data? {
    try receipt(for: operation, namespaceKey: namespaceKey, context: context)?.digest
  }

  static func record(
    _ operation: CloudFullReceiptOperation,
    namespaceKey: String,
    digest: Data,
    context: ModelContext
  ) {
    context.insert(StoredCloudFullBatchReceipt(
      namespaceKey: namespaceKey,
      operation: operation,
      digest: digest
    ))
  }

  /// Beta 80 stored re-enable receipts under the committed-batch identity.
  /// A matching plan digest proves which operation created the ambiguous legacy row.
  static func migrateLegacyReenableReceipt(
    namespaceKey: String,
    transitionID: UUID,
    expectedDigest: Data,
    context: ModelContext
  ) throws -> Bool {
    let legacyOperation = CloudFullReceiptOperation.committedBatch(transitionID)
    guard let legacy = try receipt(
      for: legacyOperation,
      namespaceKey: namespaceKey,
      context: context
    ), legacy.digest == expectedDigest else { return false }
    record(
      .reenableTransition(transitionID),
      namespaceKey: namespaceKey,
      digest: expectedDigest,
      context: context
    )
    context.delete(legacy)
    return true
  }

  static func pruneCommittedBatches(
    namespaceKey: String,
    keeping limit: Int,
    context: ModelContext
  ) throws {
    let receipts = try context.fetch(FetchDescriptor(
      predicate: #Predicate<StoredCloudFullBatchReceipt> {
        $0.namespaceKey == namespaceKey
      }
    ))
      .filter { receipt in
        CloudFullReceiptOperation.committedBatch(receipt.batchID)
          .matches(receipt, namespaceKey: namespaceKey)
      }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
        return $0.id > $1.id
      }
    for receipt in receipts.dropFirst(limit) { context.delete(receipt) }
  }

  private static func receipt(
    for operation: CloudFullReceiptOperation,
    namespaceKey: String,
    context: ModelContext
  ) throws -> StoredCloudFullBatchReceipt? {
    let id = operation.storageKey(namespaceKey: namespaceKey)
    return try context.fetch(FetchDescriptor(
      predicate: #Predicate<StoredCloudFullBatchReceipt> { $0.id == id }
    )).first
  }
}
