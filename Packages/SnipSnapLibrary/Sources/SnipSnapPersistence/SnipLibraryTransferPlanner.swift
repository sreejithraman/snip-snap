import CryptoKit
import Foundation
import SnipSnapCore

package struct SnipLibraryTransferPlan: Sendable {
  package let targetDigest: Data
  package let snips: [Snip]
  package let lists: [SnipList]
  package let attachmentData: [UUID: Data]
  package let attachmentFileURLs: [UUID: URL]
  package let attachmentFileDigests: [UUID: Data]
  package let opaqueSyncStatePayload: Data
  package let additionalSeenRequestIDs: Set<UUID>
  package let result: SnipLibraryTransferResult
}

package enum SnipLibraryTransferPlanner {
  package static func plan(
    source: SnipLibraryTransferSnapshot,
    target: SnipLibraryTransferSnapshot,
    transitionID: UUID,
    replacingTargetSnipIDs: Set<UUID> = [],
    replacingTargetListIDs: Set<UUID> = [],
    acceptedTargetSnipIDs: Set<UUID> = []
  ) throws -> SnipLibraryTransferPlan {
    let targetDigest = digest(snapshot: target)
    let targetBundle = try CloudDormantAcceptedBaseBundle.decode(target.opaqueSyncStatePayload)
    let sourceBundle = try CloudDormantAcceptedBaseBundle.decode(source.opaqueSyncStatePayload)
    let mergedSyncPayload = try targetBundle.merging(sourceBundle).encoded()
    let retainedTargetSnips = target.snips.filter { !replacingTargetSnipIDs.contains($0.id) }
    let retainedAttachmentIDs = Set(retainedTargetSnips.flatMap(\.attachments).map(\.id))
    let target = SnipLibraryTransferSnapshot(
      revision: target.revision,
      snips: retainedTargetSnips,
      lists: target.lists,
      attachmentData: target.attachmentData.filter { retainedAttachmentIDs.contains($0.key) },
      attachmentFileURLs: target.attachmentFileURLs.filter {
        retainedAttachmentIDs.contains($0.key)
      },
      attachmentFileDigests: target.attachmentFileDigests.filter {
        retainedAttachmentIDs.contains($0.key)
      },
      legacyManualPositions: target.legacyManualPositions.filter { entry in
        retainedTargetSnips.contains(where: { $0.id == entry.key })
      },
      opaqueSyncStateDigest: target.opaqueSyncStateDigest,
      opaqueSyncStatePayload: target.opaqueSyncStatePayload,
      additionalSeenRequestIDs: target.additionalSeenRequestIDs
    )
    let retainedTargetLists = target.lists.filter {
      !replacingTargetListIDs.contains($0.id)
    }
    var lists = retainedTargetLists
    var listByID = Dictionary(uniqueKeysWithValues: retainedTargetLists.map { ($0.id, $0) })
    for list in source.lists {
      if listByID[list.id] != nil { continue }
      lists.append(list)
      listByID[list.id] = list
    }
    lists = SnipListNameAllocator.resolving(lists)

    let targetAttachments = attachmentMap(target.snips)
    let sourceAttachments = attachmentMap(source.snips)
    for (id, sourceAttachment) in sourceAttachments {
      guard let sourceDigest = attachmentDigest(id: id, in: source) else {
        throw SnipLibraryError.attachmentCopyFailed
      }
      if let targetAttachment = targetAttachments[id] {
        guard targetAttachment == sourceAttachment,
          attachmentDigest(id: id, in: target) == sourceDigest
        else {
          throw SnipLibraryError.transferConflict(.attachmentIdentity(id))
        }
      }
    }

    var snips = target.snips
    let targetByID = Dictionary(uniqueKeysWithValues: target.snips.map { ($0.id, $0) })
    var approved: Set<UUID> = []
    var recovered: Set<UUID> = []
    for sourceSnip in source.snips {
      guard let targetSnip = targetByID[sourceSnip.id] else {
        snips.append(sourceSnip)
        approved.insert(sourceSnip.id)
        continue
      }
      if targetSnip == sourceSnip {
        if !acceptedTargetSnipIDs.contains(sourceSnip.id) {
          approved.insert(sourceSnip.id)
        }
        continue
      }
      let recoveredID = derivedUUID(transitionID: transitionID, sourceID: sourceSnip.id)
      let requestID = derivedUUID(transitionID: transitionID, sourceID: sourceSnip.requestID)
      if !snips.contains(where: { $0.id == recoveredID }) {
        snips.append(
          Snip(
            id: recoveredID,
            requestID: requestID,
            createdAt: sourceSnip.createdAt,
            updatedAt: sourceSnip.updatedAt,
            content: sourceSnip.content,
            origin: sourceSnip.origin,
            source: sourceSnip.source,
            listID: listByID[sourceSnip.listID] == nil ? SnipList.inboxID : sourceSnip.listID,
            isDone: sourceSnip.isDone,
            pinnedAt: sourceSnip.pinnedAt,
            manualSortKey: sourceSnip.manualSortKey,
            attachments: sourceSnip.attachments
          )
        )
      }
      approved.insert(recoveredID)
      recovered.insert(sourceSnip.id)
    }

    let targetAttachmentIDs = Set(target.attachmentData.keys)
      .union(target.attachmentFileURLs.keys)
    return SnipLibraryTransferPlan(
      targetDigest: targetDigest,
      snips: snips,
      lists: lists,
      attachmentData: target.attachmentData.merging(source.attachmentData) { target, _ in target },
      attachmentFileURLs: target.attachmentFileURLs.merging(
        source.attachmentFileURLs.filter { !targetAttachmentIDs.contains($0.key) }
      ) { target, _ in target },
      attachmentFileDigests: target.attachmentFileDigests.merging(
        source.attachmentFileDigests.filter { !targetAttachmentIDs.contains($0.key) }
      ) { target, _ in target },
      opaqueSyncStatePayload: mergedSyncPayload,
      additionalSeenRequestIDs: source.additionalSeenRequestIDs,
      result: SnipLibraryTransferResult(
        approvedSnipIDs: approved,
        recoveredSourceSnipIDs: recovered
      )
    )
  }

  package static func digest(
    snip: Snip?,
    attachmentData: [UUID: Data],
    attachmentFileDigests: [UUID: Data] = [:],
    version: Int = 3,
    legacyManualPosition: Int64? = nil
  ) -> Data {
    var bytes = Data("snipsnap-mode-seed-v\(version)".utf8)
    guard let snip else {
      bytes.append(0)
      return Data(SHA256.hash(data: bytes))
    }
    bytes.append(1)
    append(snip.id.uuidString.lowercased(), to: &bytes)
    append(snip.requestID.uuidString.lowercased(), to: &bytes)
    append(snip.createdAt.timeIntervalSinceReferenceDate.bitPattern, to: &bytes)
    append(snip.updatedAt.timeIntervalSinceReferenceDate.bitPattern, to: &bytes)
    append(snip.content, to: &bytes)
    append(snip.origin.rawValue, to: &bytes)
    if let source = snip.source {
      bytes.append(1)
      append(source.applicationName, to: &bytes)
      append(source.windowTitle, to: &bytes)
      append(source.url, to: &bytes)
      if let context = source.agentContext {
        append(context.sessionTitle, to: &bytes)
        append(context.branchName, to: &bytes)
      }
    } else {
      bytes.append(0)
    }
    append(snip.listID.uuidString.lowercased(), to: &bytes)
    bytes.append(snip.isDone ? 1 : 0)
    if version >= 3 {
      if let pinnedAt = snip.pinnedAt {
        bytes.append(1)
        append(pinnedAt.timeIntervalSince1970.bitPattern, to: &bytes)
      } else { bytes.append(0) }
    }
    if version == 1 {
      append(UInt64(bitPattern: legacyManualPosition ?? snip.manualPosition), to: &bytes)
    } else {
      append(snip.manualSortKey.data, to: &bytes)
    }
    append(UInt64(snip.attachments.count), to: &bytes)
    for attachment in snip.attachments {
      append(attachment.id.uuidString.lowercased(), to: &bytes)
      append(attachment.fileName, to: &bytes)
      append(attachment.contentType, to: &bytes)
      append(UInt64(bitPattern: attachment.byteCount), to: &bytes)
      if let data = attachmentData[attachment.id] {
        bytes.append(1)
        append(Data(SHA256.hash(data: data)), to: &bytes)
      } else if let digest = attachmentFileDigests[attachment.id] {
        bytes.append(1)
        append(digest, to: &bytes)
      } else {
        bytes.append(0)
      }
    }
    return Data(SHA256.hash(data: bytes))
  }

  package static func digest(snapshot: SnipLibraryTransferSnapshot) -> Data {
    var bytes = Data("snipsnap-transfer-snapshot-v2".utf8)
    append(snapshot.revision, to: &bytes)
    append(UInt64(snapshot.lists.count), to: &bytes)
    for list in snapshot.lists {
      append(list.id.uuidString.lowercased(), to: &bytes)
      append(list.desiredName, to: &bytes)
      append(list.resolvedName, to: &bytes)
      append(list.systemImage, to: &bytes)
      append(list.color?.rawValue ?? "", to: &bytes)
      append(list.sortKey.data, to: &bytes)
    }
    append(UInt64(snapshot.snips.count), to: &bytes)
    for snip in snapshot.snips {
      append(
        digest(
          snip: snip,
          attachmentData: snapshot.attachmentData,
          attachmentFileDigests: snapshot.attachmentFileDigests
        ),
        to: &bytes
      )
    }
    append(snapshot.opaqueSyncStateDigest, to: &bytes)
    return Data(SHA256.hash(data: bytes))
  }

  private static func attachmentDigest(
    id: UUID,
    in snapshot: SnipLibraryTransferSnapshot
  ) -> Data? {
    if let data = snapshot.attachmentData[id] {
      return Data(SHA256.hash(data: data))
    }
    return snapshot.attachmentFileDigests[id]
  }

  package static func derivedUUID(transitionID: UUID, sourceID: UUID) -> UUID {
    var input = Data()
    withUnsafeBytes(of: transitionID.uuid) { input.append(contentsOf: $0) }
    withUnsafeBytes(of: sourceID.uuid) { input.append(contentsOf: $0) }
    var bytes = Array(SHA256.hash(data: input).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }

  private static func attachmentMap(_ snips: [Snip]) -> [UUID: SnipAttachment] {
    Dictionary(
      snips.flatMap(\.attachments).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  fileprivate static func append(_ value: String?, to data: inout Data) {
    guard let value else {
      data.append(0)
      return
    }
    data.append(1)
    append(value, to: &data)
  }

  package static func append(_ value: String, to data: inout Data) {
    append(Data(value.utf8), to: &data)
  }

  package static func append(_ value: Data, to data: inout Data) {
    append(UInt64(value.count), to: &data)
    data.append(value)
  }

  fileprivate static func append(_ value: UInt64, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
  }
}
