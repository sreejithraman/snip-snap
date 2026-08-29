import CryptoKit
import Foundation
import SnipSnapCore
import SwiftData


extension SwiftDataSnipLibrary {
  package func commitCloudFullBatch(
    _ batch: CloudFullBatchCommit
  ) throws -> CloudFullBatchCommitResult {
    guard batch.storageVersion == 1 else { throw CloudFullStorageError.invalidBatchReplay }
    guard let container else { throw SnipLibraryError.storeUnavailable }
    let lock = try SnipStoreFileLock(url: lockURL)
    defer { withExtendedLifetime(lock) {} }
    let context = Self.makeContext(container: container)
    let data = try Self.fullBatchData(batch)
    let digest = Self.batchReceiptDigest(batch, encoded: data)
    let receiptID = StoredCloudFullBatchReceipt.key(
      namespaceKey: batch.namespaceKey,
      batchID: batch.batchID
    )
    if let receipt = try context.fetch(FetchDescriptor<StoredCloudFullBatchReceipt>())
      .first(where: { $0.id == receiptID })
    {
      guard receipt.digest == digest else { throw CloudFullStorageError.invalidBatchReplay }
      return .replayed
    }
    let stagedID = "\(batch.namespaceKey)|\(batch.batchID.uuidString.lowercased())"
    guard let staged = try context.fetch(FetchDescriptor<StoredCloudStagedBatch>())
      .first(where: { $0.id == stagedID }), staged.payload == data
    else { throw CloudFullStorageError.invalidBatchReplay }
    let engine = try context.fetch(FetchDescriptor<StoredCloudEngineState>())
      .first(where: { $0.namespaceKey == batch.namespaceKey })
    guard engine?.envelopeData == batch.expectedEngineState else {
      throw CloudFullStorageError.engineStateMismatch
    }
    let enrollmentRow = try context.fetch(FetchDescriptor<StoredCloudFullEnrollment>())
      .first(where: { $0.namespaceKey == batch.namespaceKey })
    let currentEnrollment = try Self.fullEnrollmentState(from: enrollmentRow?.referencesData)
    if let expected = batch.expectedNamespaceRevision {
      guard currentEnrollment.namespaceState.revision == expected,
        batch.nextNamespaceState?.revision == expected + 1
      else { throw CloudFullStorageError.namespaceStateMismatch }
    }

    let existing = try context.fetch(FetchDescriptor<StoredCloudEntityRecord>())
      .filter { $0.namespaceKey == batch.namespaceKey }
    var byDomain = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    var identityByDomain = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0.identityID) })
    var domainByIdentity = Dictionary(uniqueKeysWithValues: existing.map { ($0.identityID, $0.id) })
    var batchDomains: Set<String> = []
    var batchIdentities: Set<String> = []
    var outboundIdentities: Set<String> = []
    for binding in batch.outboundBindings {
      let identityKey = StoredCloudEntityRecord.identityKey(
        namespaceKey: batch.namespaceKey,
        identity: binding.identity
      )
      guard !binding.operationData.isEmpty,
        outboundIdentities.insert(identityKey).inserted
      else { throw CloudFullStorageError.invalidBatchReplay }
    }
    for item in batch.items {
      let domainKey = StoredCloudEntityRecord.domainKey(
        namespaceKey: batch.namespaceKey,
        reference: item.accepted.reference
      )
      let identityKey = StoredCloudEntityRecord.identityKey(
        namespaceKey: batch.namespaceKey,
        identity: item.accepted.identity
      )
      if item.acceptedAction != .quarantine {
        guard batchDomains.insert(domainKey).inserted else {
          throw CloudFullStorageError.invalidBatchReplay
        }
      }
      guard batchIdentities.insert(identityKey).inserted else {
        throw CloudFullStorageError.invalidBatchReplay
      }
    }
    var acceptedItems: [CloudFullBatchItem] = []
    var quarantineItems: [CloudQuarantineInput] = []
    for item in batch.items {
      try Self.validateLocalMutation(
        item.localMutation,
        precondition: item.localPrecondition,
        for: item.accepted,
        context: context
      )
      if let conflict = item.conflict {
        guard conflict.reference == item.accepted.reference,
          (conflict.format == .snipMergeV1 && conflict.reference.kind == .snip)
            || (conflict.format == .listMergeV1 && conflict.reference.kind == .list)
            || conflict.format == .legacyBindingV1
        else { throw CloudFullStorageError.invalidConflictReplay }
      }
      if item.acceptedAction == .quarantine {
        guard item.localMutation == .none,
          item.localPrecondition == .none,
          let quarantine = item.quarantine,
          quarantine.reference == item.accepted.reference,
          quarantine.identity == item.accepted.identity
        else { throw CloudFullStorageError.invalidBatchReplay }
        quarantineItems.append(quarantine)
        continue
      }
      let domainKey = StoredCloudEntityRecord.domainKey(
        namespaceKey: batch.namespaceKey,
        reference: item.accepted.reference
      )
      let identityKey = StoredCloudEntityRecord.identityKey(
        namespaceKey: batch.namespaceKey,
        identity: item.accepted.identity
      )
      let domainCollision = identityByDomain[domainKey].map { $0 != identityKey } ?? false
      let identityCollision = domainByIdentity[identityKey].map { $0 != domainKey } ?? false
      if domainCollision || identityCollision {
        guard item.acceptedAction == .upsert else {
          throw CloudFullStorageError.staleAcceptedEntity
        }
        guard let quarantine = item.quarantine,
          quarantine.reference == item.accepted.reference,
          quarantine.identity == item.accepted.identity,
          item.localMutation == .none,
          item.localPrecondition == .none
        else { throw CloudFullStorageError.invalidBatchReplay }
        quarantineItems.append(quarantine)
        continue
      }
      if let current = byDomain[domainKey] {
        if item.acceptedAction == .remove {
          guard current.identityID == identityKey,
            item.expectedLocalRevision == current.localRevision,
            item.expectedSystemFields == current.systemFields
          else { throw CloudFullStorageError.staleAcceptedEntity }
          acceptedItems.append(item)
          continue
        }
        let exactReplay = current.matches(item.accepted, isDeferred: current.isDeferred)
        if !exactReplay {
          guard item.expectedLocalRevision == current.localRevision,
            item.expectedSystemFields == current.systemFields
          else { throw CloudFullStorageError.staleAcceptedEntity }
        }
      } else {
        guard item.acceptedAction == .upsert,
          item.expectedLocalRevision == nil,
          item.expectedSystemFields == nil
        else { throw CloudFullStorageError.staleAcceptedEntity }
      }
      acceptedItems.append(item)
      identityByDomain[domainKey] = identityKey
      domainByIdentity[identityKey] = domainKey
    }

    var knownLists: Set<UUID> = [SnipList.inbox.id]
    knownLists.formUnion(existing.compactMap {
      $0.kind == CloudEntityKind.list.rawValue && !$0.isDeferred ? $0.domainID : nil
    })
    knownLists.subtract(acceptedItems.compactMap {
      $0.acceptedAction == .remove && $0.accepted.reference.kind == .list
        ? $0.accepted.reference.domainID : nil
    })
    knownLists.formUnion(acceptedItems.compactMap {
      $0.acceptedAction == .upsert && $0.accepted.reference.kind == .list
        ? $0.accepted.reference.domainID : nil
    })
    do {
      for recovery in batch.recoveryInputs {
        guard recovery.namespaceKey == batch.namespaceKey,
          recovery.batchID == batch.batchID,
          recovery.storageVersion == 1
        else { throw CloudFullStorageError.invalidBatchReplay }
        try Self.insertFullRecoveryIfNeeded(recovery, context: context)
      }
      for quarantine in quarantineItems {
        try Self.insertQuarantineIfNeeded(
          quarantine,
          namespaceKey: batch.namespaceKey,
          context: context
        )
      }
      for item in acceptedItems {
        let value = item.accepted
        let domainKey = StoredCloudEntityRecord.domainKey(
          namespaceKey: batch.namespaceKey,
          reference: value.reference
        )
        if item.acceptedAction == .remove {
          guard let current = byDomain.removeValue(forKey: domainKey) else {
            throw CloudFullStorageError.staleAcceptedEntity
          }
          context.delete(current)
          if let conflict = item.conflict {
            try Self.insertConflictIfNeeded(
              conflict,
              namespaceKey: batch.namespaceKey,
              context: context
            )
          }
          try Self.applyLocalMutation(item.localMutation, context: context)
          continue
        }
        if value.reference.kind == .snip, value.dependencyListID == nil {
          throw CloudFullStorageError.missingListDependency
        }
        let deferred = value.reference.kind == .snip
          && value.dependencyListID.map { !knownLists.contains($0) } == true
        let deferredData = deferred
          ? try JSONEncoder().encode(
            CloudDeferredLocalMutation(
              precondition: item.localPrecondition,
              mutation: item.localMutation
            )
          )
          : nil
        if let current = byDomain[domainKey] {
          if !current.matches(value, isDeferred: deferred) {
            current.replace(
              with: value,
              isDeferred: deferred,
              deferredMutationData: deferredData
            )
          }
        } else {
          let record = StoredCloudEntityRecord(
            namespaceKey: batch.namespaceKey,
            value: value,
            isDeferred: deferred,
            deferredMutationData: deferredData
          )
          context.insert(record)
          byDomain[domainKey] = record
        }
        if let conflict = item.conflict {
          try Self.insertConflictIfNeeded(
            conflict,
            namespaceKey: batch.namespaceKey,
            context: context
          )
        }
        if !deferred {
          try Self.applyLocalMutation(item.localMutation, context: context)
        }
      }
      for record in byDomain.values where record.isDeferred {
        guard let dependency = record.dependencyListID,
          knownLists.contains(dependency),
          let mutationData = record.deferredMutationData
        else { continue }
        let deferred = try JSONDecoder().decode(CloudDeferredLocalMutation.self, from: mutationData)
        guard deferred.storageVersion == 1 else {
          throw CloudFullStorageError.invalidLocalMutation
        }
        try Self.validateLocalMutation(
          deferred.mutation,
          precondition: deferred.precondition,
          for: CloudAcceptedEntityInput(
            reference: try Self.entity(from: record).reference,
            identity: record.identity,
            schemaVersion: record.schemaVersion,
            acceptedData: record.acceptedData,
            presenceData: record.presenceData,
            shadowData: record.shadowData,
            systemFields: record.systemFields,
            dependencyListID: record.dependencyListID
          ),
          context: context
        )
        try Self.applyLocalMutation(deferred.mutation, context: context)
        record.isDeferred = false
        record.deferredMutationData = nil
      }
      try Self.resolveStoredListNames(context: context)
      let final = try Self.load(context: context, seenRequestIDs: seenRequestIDs)
      do {
        try Self.validate(final.state)
      } catch {
        throw CloudFullStorageError.invalidLocalMutation
      }
      let enrollment = batch.nextEnrollment ?? currentEnrollment.references
      if batch.nextEnrollment != nil || batch.nextNamespaceState != nil {
        let listReferences = Set(enrollment.filter { $0.kind == .list }.map(\.domainID))
        let snipReferences = enrollment.filter { $0.kind == .snip }
        let localByID = Dictionary(uniqueKeysWithValues: final.state.snips.map { ($0.id, $0) })
        let acceptedByID = Dictionary(uniqueKeysWithValues:
          try context.fetch(FetchDescriptor<StoredCloudEntityRecord>())
            .filter { $0.namespaceKey == batch.namespaceKey && $0.kind == CloudEntityKind.snip.rawValue }
            .map { ($0.domainID, $0) }
        )
        guard snipReferences.allSatisfy({ reference in
          let dependency = localByID[reference.domainID]?.listID
            ?? acceptedByID[reference.domainID]?.dependencyListID
          return dependency.map(listReferences.contains) ?? false
        }) else { throw CloudFullStorageError.invalidEnrollment }
        let state = batch.nextNamespaceState ?? currentEnrollment.namespaceState
        let data = try JSONEncoder().encode(
          CloudFullEnrollmentState(namespaceState: state, references: enrollment)
        )
        if let enrollmentRow {
          enrollmentRow.referencesData = data
        } else {
          context.insert(
            StoredCloudFullEnrollment(namespaceKey: batch.namespaceKey, referencesData: data)
          )
        }
      }
      context.delete(staged)
      if let next = batch.nextEngineState {
        if let engine { engine.envelopeData = next }
        else {
          context.insert(
            StoredCloudEngineState(namespaceKey: batch.namespaceKey, envelopeData: next)
          )
        }
      } else if let engine {
        context.delete(engine)
      }
      context.insert(
        StoredCloudFullBatchReceipt(
          namespaceKey: batch.namespaceKey,
          batchID: batch.batchID,
          digest: digest
        )
      )
      let receipts = try context.fetch(FetchDescriptor<StoredCloudFullBatchReceipt>())
        .filter { $0.namespaceKey == batch.namespaceKey }
        .sorted {
          if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
          return $0.id > $1.id
        }
      for receipt in receipts.dropFirst(256) { context.delete(receipt) }
      try afterMutationBeforeSave()
      try context.save()
    } catch {
      context.rollback()
      throw error
    }
    let loaded = try Self.load(
      context: Self.makeContext(container: container),
      seenRequestIDs: seenRequestIDs
    )
    lastKnownState = loaded.state
    seenRequestIDs = loaded.state.seenRequestIDs
    return .applied
  }

}
