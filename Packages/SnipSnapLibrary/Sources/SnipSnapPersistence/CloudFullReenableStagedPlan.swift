import CryptoKit
import Foundation
import SnipSnapCore

private struct CloudFullReenableLegacyColor: Codable {
  let light: String
  let dark: String
}

private struct CloudFullReenableLegacyList: Codable {
  let id: UUID
  let name: String
  let desiredName: String
  let resolvedName: String
  let systemImage: String
  let color: CloudFullReenableLegacyColor?
  let position: Int
  let sortKey: SnipOrderKey

  private enum CodingKeys: String, CodingKey {
    case id, name, desiredName, resolvedName, systemImage, color, position, sortKey
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(desiredName, forKey: .desiredName)
    try container.encode(resolvedName, forKey: .resolvedName)
    try container.encode(systemImage, forKey: .systemImage)
    try container.encode(color, forKey: .color)
    try container.encode(position, forKey: .position)
    try container.encode(sortKey, forKey: .sortKey)
  }

  var current: SnipList {
    SnipList(
      id: id,
      desiredName: desiredName,
      resolvedName: resolvedName,
      systemImage: systemImage,
      color: nil,
      sortKey: sortKey
    )
  }
}

private struct CloudFullReenableListEncodingProbe: Decodable {
  let isLegacy: Bool
  private enum CodingKeys: String, CodingKey { case color }

  init(from decoder: any Decoder) throws {
    isLegacy = try decoder.container(keyedBy: CodingKeys.self).contains(.color)
  }
}

private enum CloudFullReenableLegacyJSON: Codable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([Self])
  case object([String: Self])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(Int64.self) { self = .integer(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([Self].self) { self = .array(value) }
    else { self = .object(try container.decode([String: Self].self)) }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

package struct CloudFullReenableStagedPlan: Codable {
  struct AttachmentFile: Codable {
    let id: UUID
    let relativePath: String
    let digest: Data
  }

  let storageVersion: Int
  let transitionID: UUID
  let namespaceKey: String
  let expectedNamespaceRevision: UInt64
  let targetRevision: UInt64
  let targetDigest: Data
  let snips: [Snip]
  let lists: [SnipList]
  let dormantPayload: Data
  let acceptedCAS: [CloudFullReenableAcceptedCAS]
  let conflicts: [CloudConflictInput]
  let recoveryInputs: [CloudFullRecoveryInput]
  let result: SnipLibraryTransferResult
  let attachmentFiles: [AttachmentFile]
  let planDigest: Data
  private let legacyLists: [CloudFullReenableLegacyList]?
  private let legacyConflicts: [CloudFullReenableLegacyJSON]?

  package struct Restored {
    package let plan: CloudFullReenableApplyPlan
    package let acceptedLegacyDigest: Data?
  }

  package init(plan: CloudFullReenableApplyPlan) {
    storageVersion = 1
    transitionID = plan.transitionID
    namespaceKey = plan.namespaceKey
    expectedNamespaceRevision = plan.expectedNamespaceRevision
    targetRevision = plan.targetRevision
    targetDigest = plan.targetDigest
    snips = plan.snips
    lists = plan.lists
    dormantPayload = plan.dormantPayload
    acceptedCAS = plan.acceptedCAS
    conflicts = plan.conflicts
    recoveryInputs = plan.recoveryInputs
    result = plan.result
    attachmentFiles = plan.attachmentData.map { id, data in
      let digest = Data(SHA256.hash(data: data))
      return AttachmentFile(
        id: id,
        relativePath: "attachments/\(Self.hex(digest)).data",
        digest: digest
      )
    }.sorted { $0.id.uuidString < $1.id.uuidString }
    planDigest = plan.planDigest
    legacyLists = nil
    legacyConflicts = nil
  }

  package func restore(from root: URL) throws -> Restored {
    guard storageVersion == 1,
      Set(attachmentFiles.map(\.id)).count == attachmentFiles.count
    else { throw SyncModePersistenceError.invalidManifest }
    var attachmentData: [UUID: Data] = [:]
    for file in attachmentFiles {
      let expectedPath = "attachments/\(Self.hex(file.digest)).data"
      guard file.relativePath == expectedPath else {
        throw SyncModePersistenceError.invalidManifest
      }
      let data = try Data(contentsOf: root.appendingPathComponent(file.relativePath))
      guard Data(SHA256.hash(data: data)) == file.digest else {
        throw SyncModePersistenceError.invalidManifest
      }
      attachmentData[file.id] = data
    }
    let plan = try CloudFullReenableApplyPlan(
      transitionID: transitionID,
      namespaceKey: namespaceKey,
      expectedNamespaceRevision: expectedNamespaceRevision,
      targetRevision: targetRevision,
      targetDigest: targetDigest,
      snips: snips,
      lists: lists,
      attachmentData: attachmentData,
      dormantPayload: dormantPayload,
      acceptedCAS: acceptedCAS,
      conflicts: conflicts,
      recoveryInputs: recoveryInputs,
      result: result
    )
    if plan.planDigest == planDigest {
      return Restored(plan: plan, acceptedLegacyDigest: nil)
    }
    guard let legacyLists, let legacyConflicts,
      try legacyDigest(
        attachmentData: attachmentData,
        lists: legacyLists,
        conflicts: legacyConflicts
      ) == planDigest
    else { throw SyncModePersistenceError.invalidManifest }
    return Restored(plan: plan, acceptedLegacyDigest: planDigest)
  }

  private enum CodingKeys: String, CodingKey {
    case storageVersion, transitionID, namespaceKey, expectedNamespaceRevision
    case targetRevision, targetDigest, snips, lists, dormantPayload, acceptedCAS
    case conflicts, recoveryInputs, result, attachmentFiles, planDigest
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    storageVersion = try container.decode(Int.self, forKey: .storageVersion)
    transitionID = try container.decode(UUID.self, forKey: .transitionID)
    namespaceKey = try container.decode(String.self, forKey: .namespaceKey)
    expectedNamespaceRevision = try container.decode(UInt64.self, forKey: .expectedNamespaceRevision)
    targetRevision = try container.decode(UInt64.self, forKey: .targetRevision)
    targetDigest = try container.decode(Data.self, forKey: .targetDigest)
    snips = try container.decode([Snip].self, forKey: .snips)
    let probes = try container.decode([CloudFullReenableListEncodingProbe].self, forKey: .lists)
    if probes.contains(where: \CloudFullReenableListEncodingProbe.isLegacy) {
      guard probes.allSatisfy(\CloudFullReenableListEncodingProbe.isLegacy) else {
        throw SyncModePersistenceError.invalidManifest
      }
      let legacy = try container.decode([CloudFullReenableLegacyList].self, forKey: .lists)
      legacyLists = legacy
      lists = legacy.map(\.current)
      legacyConflicts = try container.decode(
        [CloudFullReenableLegacyJSON].self,
        forKey: .conflicts
      )
    } else {
      legacyLists = nil
      legacyConflicts = nil
      lists = try container.decode([SnipList].self, forKey: .lists)
    }
    dormantPayload = try container.decode(Data.self, forKey: .dormantPayload)
    acceptedCAS = try container.decode([CloudFullReenableAcceptedCAS].self, forKey: .acceptedCAS)
    conflicts = try container.decode([CloudConflictInput].self, forKey: .conflicts)
    recoveryInputs = try container.decode([CloudFullRecoveryInput].self, forKey: .recoveryInputs)
    result = try container.decode(SnipLibraryTransferResult.self, forKey: .result)
    attachmentFiles = try container.decode([AttachmentFile].self, forKey: .attachmentFiles)
    planDigest = try container.decode(Data.self, forKey: .planDigest)
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(storageVersion, forKey: .storageVersion)
    try container.encode(transitionID, forKey: .transitionID)
    try container.encode(namespaceKey, forKey: .namespaceKey)
    try container.encode(expectedNamespaceRevision, forKey: .expectedNamespaceRevision)
    try container.encode(targetRevision, forKey: .targetRevision)
    try container.encode(targetDigest, forKey: .targetDigest)
    try container.encode(snips, forKey: .snips)
    try container.encode(lists, forKey: .lists)
    try container.encode(dormantPayload, forKey: .dormantPayload)
    try container.encode(acceptedCAS, forKey: .acceptedCAS)
    try container.encode(conflicts, forKey: .conflicts)
    try container.encode(recoveryInputs, forKey: .recoveryInputs)
    try container.encode(result, forKey: .result)
    try container.encode(attachmentFiles, forKey: .attachmentFiles)
    try container.encode(planDigest, forKey: .planDigest)
  }

  private struct LegacyDigestInput: Codable {
    let storageVersion: Int
    let transitionID: UUID
    let namespaceKey: String
    let expectedNamespaceRevision: UInt64
    let targetRevision: UInt64
    let targetDigest: Data
    let snips: [Snip]
    let lists: [CloudFullReenableLegacyList]
    let attachmentData: [UUID: Data]
    let dormantPayload: Data
    let acceptedCAS: [CloudFullReenableAcceptedCAS]
    let conflicts: [CloudFullReenableLegacyJSON]
    let recoveryInputs: [CloudFullRecoveryInput]
    let approvedSnipIDs: Set<UUID>
    let recoveredSourceSnipIDs: Set<UUID>
  }

  private func legacyDigest(
    attachmentData: [UUID: Data],
    lists: [CloudFullReenableLegacyList],
    conflicts: [CloudFullReenableLegacyJSON]
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    let data = try encoder.encode(LegacyDigestInput(
      storageVersion: storageVersion,
      transitionID: transitionID,
      namespaceKey: namespaceKey,
      expectedNamespaceRevision: expectedNamespaceRevision,
      targetRevision: targetRevision,
      targetDigest: targetDigest,
      snips: snips,
      lists: lists,
      attachmentData: attachmentData,
      dormantPayload: dormantPayload,
      acceptedCAS: acceptedCAS,
      conflicts: conflicts,
      recoveryInputs: recoveryInputs,
      approvedSnipIDs: result.approvedSnipIDs,
      recoveredSourceSnipIDs: result.recoveredSourceSnipIDs
    ))
    return Data(SHA256.hash(data: data))
  }

  private static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }
}
