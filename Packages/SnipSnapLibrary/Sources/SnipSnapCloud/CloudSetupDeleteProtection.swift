import SnipSnapPersistence

struct CloudSetupDeleteProtection: Sendable {
  let pointers: Set<CloudTextStorageIdentity>
  let payloads: Set<CloudTextStorageIdentity>

  init(_ receipts: [CloudSetupPointerDelete] = []) {
    pointers = Set(receipts.map(\.key.pointer))
    payloads = Set(receipts.flatMap(\.payloadIdentities))
  }

  func blocks(_ operation: CloudOutboundOperation) -> Bool {
    let identity = CloudFullSyncPersistence.storageIdentity(operation.id)
    if case .delete = operation, pointers.contains(identity) { return true }
    return payloads.contains(identity)
  }
}
