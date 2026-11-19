import CloudKit
import CryptoKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

package struct CloudSetupPeerRestoreScope: Sendable {
  struct Binding: Codable, Equatable {
    let transitionID: UUID
    let sourceStoreID: UUID
    let candidateStoreID: UUID
    let namespaceKey: CloudSyncNamespaceKey

    func matches(_ transition: SyncModeTransition) -> Bool {
      transition.id == transitionID && transition.sourceStoreID == sourceStoreID
        && transition.candidateStoreID == candidateStoreID && transition.namespace?.namespaceKey == namespaceKey
    }
  }

  let transition: SyncModeTransition
  let consent: SyncedContentPeerCopyOffer?
}

struct CheckedSetupPeerCopies: Sendable {
  let batchID: UUID
  let deletedIDs: Set<UUID>
  let snips: [CloudSnipMergeFields]
  let attachments: [CloudAttachmentMetadataValue]
  let lists: [CloudListMergeFields]
  let recordIDs: Set<CloudRecordID>
  let offer: SyncedContentPeerCopyOffer

  var snipIDs: Set<UUID> { Set(snips.map(\.id)) }

  private struct VersionedRecord: Encodable {
    let id: CloudRecordID
    let schemaVersion: Int
    let routing: [String: CloudFieldValue]
    let fields: [String: CloudFieldValue]
    let changeTag: String?
    let fallbackRevision: Data?

    init(_ record: CloudRecordSnapshot) throws {
      id = record.id
      schemaVersion = record.schemaVersion
      routing = record.routingFields
      fields = record.encryptedFields
      changeTag = try record.shadow.record().recordChangeTag
      fallbackRevision = changeTag == nil ? record.shadow.systemFields : nil
    }
  }

  private struct ConsentEvidence: Encodable {
    let deletedIDs: [UUID]
    let records: [VersionedRecord]
  }

  static func read(
    _ fetched: CloudFetchedBatch, deletedIDs: Set<UUID>, dataZone: CloudZoneID,
    payloadZone: CloudZoneID, scope: CloudSetupPeerRestoreScope
  ) throws -> Self? {
    guard !deletedIDs.isEmpty, let binding = scope.transition.namespace,
      fetched.engineState?.namespace.binding == binding,
      CloudFullSyncPersistence.isCleanInitialMetadataFetch(.fetched(fetched), dataZone: dataZone)
    else { return nil }
    let all = fetched.items.filter { $0.id?.zone == dataZone }
    guard Set(all.compactMap(\.id)).count == all.count else { return nil }
    let records = all.compactMap { item -> CloudRecordSnapshot? in
      if case .record(let record) = item { return record }
      return nil
    }
    var snips: [CloudSnipMergeFields] = []
    var lists: [UUID: CloudListMergeFields] = [:]
    var attachments: [CloudAttachmentMetadataValue] = []
    var boundRecords: [CloudRecordSnapshot] = []
    for record in records {
      switch record.recordType {
      case "Snip":
        let typed = try CloudFullRecordCodec.snip(from: record)
        guard deletedIDs.contains(typed.domainID) else { continue }
        guard typed.binding == .canonical else { return nil }
        snips.append(try CloudFullSyncPersistence.snipFields(typed))
        boundRecords.append(record)
      case "List":
        let typed = try CloudFullRecordCodec.list(from: record)
        guard typed.binding == .canonical else { continue }
        lists[typed.domainID] = try CloudFullSyncPersistence.listFields(typed)
      case CloudAttachmentRecordCodec.metadataRecordType:
        let metadata = try CloudAttachmentRecordCodec.metadata(from: record, metadataZone: dataZone, payloadZone: payloadZone)
        guard deletedIDs.contains(metadata.snipID) else { continue }
        attachments.append(metadata)
        boundRecords.append(record)
      default:
        // A pointer with an unreadable type can hide membership.
        if record.id.name.hasPrefix("a-") { return nil }
      }
    }
    guard !snips.isEmpty, Set(snips.map(\.id)).count == snips.count,
      Set(attachments.map(\.attachmentID)).count == attachments.count
    else { return nil }
    let ids = Set(snips.map(\.id))
    guard attachments.allSatisfy({ ids.contains($0.snipID) }) else { return nil }
    let listIDs = Set(snips.map(\.placement.listID)).subtracting([SnipList.inbox.id])
    guard listIDs.isSubset(of: Set(lists.keys)) else { return nil }
    boundRecords += records.filter { record in listIDs.contains { .list($0, in: dataZone) == record.id } }
    let preview = snips.sorted { $0.id.uuidString < $1.id.uuidString }.map { snip in
      SyncedContentPeerCopyOffer.Copy(
        id: snip.id, content: snip.text,
        listName: lists[snip.placement.listID]?.desiredName ?? SnipList.inbox.name,
        attachmentNames: attachments.filter { $0.snipID == snip.id }
          .sorted { ($0.position, $0.attachmentID.uuidString) < ($1.position, $1.attachmentID.uuidString) }
          .map(\.fileName)
      )
    }
    let versionedRecords = try boundRecords.sorted { $0.id.name < $1.id.name }.map(VersionedRecord.init)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let scopeData = try encoder.encode(CloudSetupPeerRestoreScope.Binding(
      transitionID: scope.transition.id, sourceStoreID: scope.transition.sourceStoreID,
      candidateStoreID: scope.transition.candidateStoreID, namespaceKey: binding.namespaceKey
    ))
    let evidence = try encoder.encode(ConsentEvidence(
      deletedIDs: deletedIDs.sorted { $0.uuidString < $1.uuidString }, records: versionedRecords
    ))
    return Self(batchID: fetched.id, deletedIDs: deletedIDs, snips: snips, attachments: attachments,
      lists: listIDs.compactMap { lists[$0] }, recordIDs: Set(boundRecords.map(\.id))
        .union(attachments.map { CloudAttachmentRecordCodec.recordID($0.payloadIdentity) }),
      offer: .init(copies: preview, scope: scopeData, evidence: Data(SHA256.hash(data: evidence))))
  }
}

extension CloudFullSyncPersistence {
  func inspectSetupPeerCopies(in batch: CloudSyncBatch, deletedIDs: Set<UUID>) async throws {
    guard case .fetched(let fetched) = batch, let setupPeerRestore, let payloadZone else { return }
    checkedSetupPeerCopies = nil
    guard let checked = try? CheckedSetupPeerCopies.read(
      fetched, deletedIDs: deletedIDs, dataZone: dataZone, payloadZone: payloadZone, scope: setupPeerRestore
    ) else { return }
    let publications = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey).publications
    let reported = Set(fetched.items.compactMap(\.id).map(Self.storageIdentity))
    guard publications.allSatisfy({
      !checked.snipIDs.contains($0.metadata.snipID) || reported.contains($0.metadataIdentity)
    }) else { return }
    guard try await !setupRetryHasCandidateChanges(for: deletedIDs, allowingCheckedPeers: checked.snipIDs) else { return }
    checkedSetupPeerCopies = checked
  }

  func authorizedSetupPeers(for deletedIDs: Set<UUID>, batchID: UUID? = nil) -> Set<UUID> {
    guard let checkedSetupPeerCopies, checkedSetupPeerCopies.deletedIDs == deletedIDs,
      batchID.map({ $0 == checkedSetupPeerCopies.batchID }) ?? true,
      setupPeerRestore?.consent == checkedSetupPeerCopies.offer
    else { return [] }
    return checkedSetupPeerCopies.snipIDs
  }

  func confirmedSetupPeerCopyMatchesCandidate() async throws -> Bool {
    guard let checked = checkedSetupPeerCopies else { return false }
    let candidate = try await library.checkedSnapshot(sortedBy: .manual)
    let storage = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let accepted = Dictionary(uniqueKeysWithValues: storage.readyEntities.map { ($0.reference, $0) })
    for fields in checked.snips {
      guard let snip = candidate.snips.first(where: { $0.id == fields.id }),
        let base = accepted[.init(kind: .snip, domainID: fields.id)],
        try Self.snipFields(Self.snipRecord(base)) == fields,
        try Self.sameSnipFields(Self.snipFields(snip, accepted: Self.snipRecord(base)), fields),
        Set(snip.attachments.map(\.id)) == Set(checked.attachments.filter { $0.snipID == fields.id }.map(\.attachmentID))
      else { return false }
    }
    for fields in checked.lists {
      guard let list = candidate.lists.first(where: { $0.id == fields.id }),
        list.name == fields.desiredName,
        Self.sameListFields(Self.listFields(list, updatedAt: fields.updatedAt), fields)
      else { return false }
    }
    let publications = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey).publications
      .filter { checked.snipIDs.contains($0.metadata.snipID) && $0.isLocallyPresent }
    return publications.allSatisfy { $0.metadataAccepted && checked.attachments.contains($0.metadata) }
      && publications.count == checked.attachments.count
  }
}
