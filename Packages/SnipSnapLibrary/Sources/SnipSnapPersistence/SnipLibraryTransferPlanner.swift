import CryptoKit
import Foundation
import SnipSnapCore

package struct SnipLibraryTransferPlan: Sendable {
  package let targetRevision: UInt64
  package let targetDigest: Data
  package let snips: [Snip]
  package let lists: [SnipList]
  package let attachmentData: [UUID: Data]
  package let attachmentFileURLs: [UUID: URL]
  package let attachmentFileDigests: [UUID: Data]
  package let opaqueSyncStateDigest: Data
  package let opaqueSyncStatePayload: Data
  package let result: SnipLibraryTransferResult

  package var digest: Data {
    var bytes = Data("snipsnap-transfer-plan-v1".utf8)
    SnipLibraryTransferPlanner.append(targetRevision, to: &bytes)
    SnipLibraryTransferPlanner.append(targetDigest, to: &bytes)
    SnipLibraryTransferPlanner.append(
      SnipLibraryTransferPlanner.digest(
        snapshot: SnipLibraryTransferSnapshot(
          revision: targetRevision,
          snips: snips,
          lists: lists,
          attachmentData: attachmentData,
          attachmentFileURLs: attachmentFileURLs,
          attachmentFileDigests: attachmentFileDigests,
          legacyManualPositions: [:],
          opaqueSyncStateDigest: opaqueSyncStateDigest,
          opaqueSyncStatePayload: opaqueSyncStatePayload
        )
      ),
      to: &bytes
    )
    for id in result.approvedSnipIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      SnipLibraryTransferPlanner.append(id.uuidString.lowercased(), to: &bytes)
    }
    bytes.append(0xff)
    for id in result.recoveredSourceSnipIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      SnipLibraryTransferPlanner.append(id.uuidString.lowercased(), to: &bytes)
    }
    return Data(SHA256.hash(data: bytes))
  }
}

package enum SnipLibraryTransferPlanner {
  package static func plan(
    source: SnipLibraryTransferSnapshot,
    target: SnipLibraryTransferSnapshot,
    transitionID: UUID,
    replacingTargetSnipIDs: Set<UUID> = [],
    replacingTargetListIDs: Set<UUID> = [],
    acceptedTargetSnipIDs: Set<UUID> = [],
    acceptedTargetTextBySnipID: [UUID: String] = [:],
    priorSeedProvenance: [SyncModeSeedProvenance] = [],
    priorServerAcceptedSnipIDs: Set<UUID> = [],
    priorSeededListIDs: Set<UUID> = []
  ) throws -> SnipLibraryTransferPlan {
    let targetRevision = target.revision
    let targetDigest = digest(snapshot: target)
    let targetBundle = try CloudDormantAcceptedBaseBundle.decode(target.opaqueSyncStatePayload)
    let sourceBundle = try CloudDormantAcceptedBaseBundle.decode(source.opaqueSyncStatePayload)
    let mergedSyncPayload = try targetBundle.merging(sourceBundle).encoded()
    let retry = try retryPlan(
      source: source,
      target: target,
      acceptedTargetSnipIDs: acceptedTargetSnipIDs,
      acceptedTargetTextBySnipID: acceptedTargetTextBySnipID,
      priorSeedProvenance: priorSeedProvenance,
      priorServerAcceptedSnipIDs: priorServerAcceptedSnipIDs
    )
    let replacingTargetSnipIDs = replacingTargetSnipIDs.union(retry.replacingTargetSnipIDs)
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
      opaqueSyncStatePayload: target.opaqueSyncStatePayload
    )
    let retainedTargetLists = target.lists.filter {
      !priorSeededListIDs.contains($0.id) && !replacingTargetListIDs.contains($0.id)
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
    for sourceSnip in retry.sourceSnips {
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
            manualSortKey: sourceSnip.manualSortKey,
            attachments: sourceSnip.attachments
          )
        )
      }
      approved.insert(recoveredID)
      recovered.insert(sourceSnip.id)
    }

    approved.formUnion(retry.approvedSnipIDs)

    let targetAttachmentIDs = Set(target.attachmentData.keys)
      .union(target.attachmentFileURLs.keys)
    return SnipLibraryTransferPlan(
      targetRevision: targetRevision,
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
      opaqueSyncStateDigest: Data(SHA256.hash(data: mergedSyncPayload)),
      opaqueSyncStatePayload: mergedSyncPayload,
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
    version: Int = 2,
    legacyManualPosition: Int64? = nil
  ) -> Data {
    var bytes = Data(version == 1 ? "snipsnap-mode-seed-v1".utf8 : "snipsnap-mode-seed-v2".utf8)
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
    } else {
      bytes.append(0)
    }
    append(snip.listID.uuidString.lowercased(), to: &bytes)
    bytes.append(snip.isDone ? 1 : 0)
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
      append(list.color?.light ?? "", to: &bytes)
      append(list.color?.dark ?? "", to: &bytes)
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

  package static func remoteDigest(snip: Snip?) -> Data {
    remoteDigest(text: snip?.content)
  }

  package static func remoteDigest(text: String?) -> Data {
    var bytes = Data("snipsnap-mode-seed-remote-v1".utf8)
    guard let text else {
      bytes.append(0)
      return Data(SHA256.hash(data: bytes))
    }
    bytes.append(1)
    append(text, to: &bytes)
    return Data(SHA256.hash(data: bytes))
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

  private struct RetryPlan {
    let sourceSnips: [Snip]
    let replacingTargetSnipIDs: Set<UUID>
    let approvedSnipIDs: Set<UUID>
  }

  private static func retryPlan(
    source: SnipLibraryTransferSnapshot,
    target: SnipLibraryTransferSnapshot,
    acceptedTargetSnipIDs: Set<UUID>,
    acceptedTargetTextBySnipID: [UUID: String],
    priorSeedProvenance: [SyncModeSeedProvenance],
    priorServerAcceptedSnipIDs: Set<UUID>
  ) throws -> RetryPlan {
    guard !priorSeedProvenance.isEmpty else {
      return RetryPlan(sourceSnips: source.snips, replacingTargetSnipIDs: [], approvedSnipIDs: [])
    }
    let sourceByID = Dictionary(uniqueKeysWithValues: source.snips.map { ($0.id, $0) })
    let targetByID = Dictionary(uniqueKeysWithValues: target.snips.map { ($0.id, $0) })
    let handledSourceIDs = Set(priorSeedProvenance.map(\.sourceSnipID))
    var sourceSnips = source.snips.filter { !handledSourceIDs.contains($0.id) }
    var replacingTargetSnipIDs: Set<UUID> = []
    var approvedSnipIDs: Set<UUID> = []

    for provenance in priorSeedProvenance {
      let local = sourceByID[provenance.sourceSnipID].map {
        translated($0, id: provenance.candidateSnipID, requestID: provenance.candidateRequestID)
      }
      let localDigest = digest(
        snip: local,
        attachmentData: source.attachmentData,
        version: provenance.digestVersion,
        legacyManualPosition: source.legacyManualPositions[provenance.sourceSnipID]
      )
      let localRemoteDigest = remoteDigest(snip: local)
      let remoteWasAccepted = priorServerAcceptedSnipIDs.contains(provenance.candidateSnipID)
      let remoteIsAccepted = acceptedTargetSnipIDs.contains(provenance.candidateSnipID)
      let remoteContent: String?
      let currentRemoteDigest: Data
      if remoteIsAccepted {
        guard let value = acceptedTargetTextBySnipID[provenance.candidateSnipID] else {
          throw SnipLibraryError.transferConflict(.snipIdentity(provenance.candidateSnipID))
        }
        remoteContent = value
        currentRemoteDigest = remoteDigest(text: value)
      } else if remoteWasAccepted {
        remoteContent = nil
        currentRemoteDigest = remoteDigest(text: nil)
      } else {
        // No accepted server value means this seed is still unsent, not remotely deleted.
        remoteContent = targetByID[provenance.candidateSnipID]?.content
        currentRemoteDigest = provenance.baseRemoteDigest
      }

      let localChanged = localDigest != provenance.baseDigest
      let localRemoteChanged = localRemoteDigest != provenance.baseRemoteDigest
      let remoteChanged = currentRemoteDigest != provenance.baseRemoteDigest
      if localRemoteDigest == currentRemoteDigest {
        if localChanged {
          replacingTargetSnipIDs.insert(provenance.candidateSnipID)
          if let local {
            sourceSnips.append(local)
            if !remoteIsAccepted && !remoteWasAccepted {
              approvedSnipIDs.insert(provenance.candidateSnipID)
            }
          }
        } else if remoteIsAccepted || remoteWasAccepted {
          if remoteContent == nil { replacingTargetSnipIDs.insert(provenance.candidateSnipID) }
        } else if let local {
          sourceSnips.append(local)
          approvedSnipIDs.insert(provenance.candidateSnipID)
        } else {
          replacingTargetSnipIDs.insert(provenance.candidateSnipID)
        }
      } else if !localRemoteChanged {
        if remoteContent == nil, localChanged {
          throw SnipLibraryError.transferConflict(.snipIdentity(provenance.sourceSnipID))
        }
        if localChanged, let local, let remoteContent {
          replacingTargetSnipIDs.insert(provenance.candidateSnipID)
          sourceSnips.append(combining(remoteContent: remoteContent, with: local))
        } else if remoteContent == nil {
          replacingTargetSnipIDs.insert(provenance.candidateSnipID)
        }
      } else if !remoteChanged {
        replacingTargetSnipIDs.insert(provenance.candidateSnipID)
        if let local {
          sourceSnips.append(local)
          if !remoteIsAccepted || localRemoteDigest != currentRemoteDigest {
            approvedSnipIDs.insert(provenance.candidateSnipID)
          }
        }
      } else {
        throw SnipLibraryError.transferConflict(.snipIdentity(provenance.sourceSnipID))
      }
    }
    return RetryPlan(
      sourceSnips: sourceSnips,
      replacingTargetSnipIDs: replacingTargetSnipIDs,
      approvedSnipIDs: approvedSnipIDs
    )
  }

  private static func translated(_ snip: Snip, id: UUID, requestID: UUID) -> Snip {
    Snip(
      id: id,
      requestID: requestID,
      createdAt: snip.createdAt,
      updatedAt: snip.updatedAt,
      content: snip.content,
      origin: snip.origin,
      source: snip.source,
      listID: snip.listID,
      isDone: snip.isDone,
      manualSortKey: snip.manualSortKey,
      attachments: snip.attachments
    )
  }

  private static func combining(remoteContent: String, with local: Snip) -> Snip {
    var combined = local
    combined.content = remoteContent
    return combined
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
