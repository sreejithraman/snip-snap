import Foundation
import SnipSnapCore
import SnipSnapPersistence

extension SwiftDataCloudTextPersistence {
  nonisolated static func fetchedMutations(
      values: [CloudTextFetchedValue],
      deletedIdentities: [CloudTextStorageIdentity],
      recoveryDataByIdentity: [CloudTextStorageIdentity: Data],
      deletionRecoveryData: [CloudTextStorageIdentity: Data],
      current: CloudTextStorageSnapshot
  ) throws -> [CloudTextFetchedMutation] {
      let records = Dictionary(uniqueKeysWithValues: current.records.map { ($0.identity, $0) })
      let snips = Dictionary(uniqueKeysWithValues: current.snips.map { ($0.id, $0) })
      var nextManualPosition = current.snips.map(\.manualPosition).min() ?? 1
      var mutations: [CloudTextFetchedMutation] = []

      for value in values {
          let existingRecord = records[value.identity]
          let existingSnip = snips[value.snipID]
          guard let recoveryData = recoveryDataByIdentity[value.identity] else {
              throw CloudTransportError.invalidRecord
          }
          if existingRecord != nil, existingSnip == nil {
              if let existingRecord,
                  Self.isModeRetryDeletion(Self.recoveryInput(existingRecord.recoveryData))
              {
                  mutations.append(
                      CloudTextFetchedMutation(
                          record: .acceptAndRecover(
                              value,
                              recoveryData: try Self.encode(.modeRetryDeletion)
                          ),
                          local: .requireMissing(id: value.snipID)
                      )
                  )
              } else {
                  mutations.append(
                      CloudTextFetchedMutation(
                          record: .acceptAndRecover(value, recoveryData: recoveryData),
                          local: .requireMissing(id: value.snipID)
                      )
                  )
              }
          } else if let existingSnip {
              let isDirty = existingRecord?.acceptedText != existingSnip.content
              if isDirty, existingSnip.content != value.text {
                  mutations.append(
                      CloudTextFetchedMutation(
                          record: .acceptAndRecover(value, recoveryData: recoveryData),
                          local: .keep(id: existingSnip.id, expectedText: existingSnip.content)
                      )
                  )
              } else {
                  mutations.append(
                      CloudTextFetchedMutation(
                          record: .accept(value),
                          local: .replace(
                              id: existingSnip.id,
                              expectedText: existingSnip.content,
                              text: value.text,
                              updatedAt: Date()
                          )
                      )
                  )
              }
          } else {
              nextManualPosition -= 1
              mutations.append(
                  CloudTextFetchedMutation(
                      record: .accept(value),
                      local: .insert(
                          Snip(
                              id: value.snipID,
                              content: value.text,
                              origin: .quickEntry,
                              listID: SnipList.inboxID,
                              manualPosition: nextManualPosition
                          )
                      )
                  )
              )
          }
      }

      for identity in deletedIdentities {
          guard let record = records[identity] else { continue }
          guard let recoveryData = deletionRecoveryData[identity] else {
              throw CloudTransportError.invalidRecord
          }
          if let snip = snips[record.snipID] {
              if record.acceptedText != snip.content {
                  mutations.append(
                      CloudTextFetchedMutation(
                          record: .clearAndRecover(identity, recoveryData: recoveryData),
                          local: .keep(id: snip.id, expectedText: snip.content)
                      )
                  )
              } else {
                  mutations.append(
                      CloudTextFetchedMutation(
                          record: .remove(identity),
                          local: .delete(id: snip.id, expectedText: snip.content)
                      )
                  )
              }
          } else {
              mutations.append(
                  CloudTextFetchedMutation(
                      record: .remove(identity),
                      local: .requireMissing(id: record.snipID)
                  )
              )
          }
      }
      return mutations
  }

  nonisolated static func nextNamespaceStateAfterFetch(
      current: CloudTextStorageSnapshot,
      fetchedValues: [CloudTextFetchedValue],
      hasMissingZone: Bool,
      hasDestructiveReset: Bool,
      hasIncompleteFetch: Bool
  ) -> CloudNamespaceStateStorage {
      let state = current.namespaceState
      if hasDestructiveReset {
          return CloudNamespaceStateStorage(
              phase: .blocked,
              approvedSnipIDs: state.approvedSnipIDs,
              excludedSnipIDs: state.excludedSnipIDs
          )
      }
      if state.phase == .blocked { return state }
      if hasMissingZone {
          switch state.phase {
          case .active:
              return CloudNamespaceStateStorage(
                  phase: .blocked,
                  excludedSnipIDs: state.excludedSnipIDs
              )
          case .seeding:
              return CloudNamespaceStateStorage(
                  phase: .seeding,
                  approvedSnipIDs: state.approvedSnipIDs,
                  excludedSnipIDs: state.excludedSnipIDs,
                  zoneCreationPending: true
              )
          case .notEnrolled, .remoteChecked, .remoteCheckedMissingZone:
              return CloudNamespaceStateStorage(
                  phase: .remoteCheckedMissingZone,
                  excludedSnipIDs: state.excludedSnipIDs
              )
          case .blocked:
              return state
          }
      }
      if hasIncompleteFetch { return state }
      if state.phase == .active {
          return CloudNamespaceStateStorage(
              phase: .active,
              excludedSnipIDs: state.excludedSnipIDs
          )
      }
      if state.phase == .seeding {
          return state
      }
      if !fetchedValues.isEmpty {
          let remoteIDs = Set(fetchedValues.map(\.snipID))
          return CloudNamespaceStateStorage(
              phase: .active,
              excludedSnipIDs: Set(current.snips.map(\.id)).subtracting(remoteIDs)
          )
      }
      return CloudNamespaceStateStorage(
          phase: .remoteChecked,
          excludedSnipIDs: state.excludedSnipIDs
      )
  }

  nonisolated static func hasIncompleteFetch(_ batch: CloudFetchedBatch) -> Bool {
      batch.items.contains {
          guard case .failed(_, let failure) = $0 else { return false }
          return failure != .zoneMissing
      } || batch.databaseEvents.contains {
          guard case .failed(_, let failure) = $0 else { return false }
          return failure != .zoneMissing
      } || batch.zoneEvents.contains {
          guard case .failed(_, let failure) = $0 else { return false }
          return failure != .zoneMissing
      }
  }

  nonisolated static func nextNamespaceStateAfterSend(
      current: CloudTextStorageSnapshot,
      batch: CloudSentBatch,
      textZone: CloudZoneID
  ) -> CloudNamespaceStateStorage {
      var state = current.namespaceState
      if batch.databaseEvents.contains(where: isDestructiveReset) {
          return CloudNamespaceStateStorage(
              phase: .blocked,
              approvedSnipIDs: state.approvedSnipIDs,
              excludedSnipIDs: state.excludedSnipIDs
          )
      }
      if hasMissingZone(batch, textZone: textZone) {
          if state.phase == .seeding {
              return CloudNamespaceStateStorage(
                  phase: .seeding,
                  approvedSnipIDs: state.approvedSnipIDs,
                  excludedSnipIDs: state.excludedSnipIDs,
                  zoneCreationPending: true
              )
          }
          return CloudNamespaceStateStorage(
              phase: .blocked,
              approvedSnipIDs: state.approvedSnipIDs,
              excludedSnipIDs: state.excludedSnipIDs
          )
      }
      guard state.phase == .seeding else { return state }
      if state.zoneCreationPending {
          let zoneWasSaved = batch.databaseEvents.contains(where: { event in
             guard case .zoneSaved(let zone) = event else { return false }
             return zone == textZone
          })
          guard zoneWasSaved else { return state }
          state = CloudNamespaceStateStorage(
              phase: state.phase,
              approvedSnipIDs: state.approvedSnipIDs,
              excludedSnipIDs: state.excludedSnipIDs,
              zoneCreationPending: false
          )
      }
      let recordByIdentity = Dictionary(
          uniqueKeysWithValues: current.records.map { ($0.identity, $0) }
      )
      var completed = Set(
          current.records.filter { $0.acceptedText != nil }.map(\.snipID)
      )
      for item in batch.items {
          let id: CloudRecordID
          let isTerminal: Bool
          switch item {
          case .saved(let snapshot):
              id = snapshot.id
              isTerminal = true
          case .conflict(let recordID, _), .unknownItem(let recordID):
              id = recordID
              isTerminal = true
          case .failed(let recordID, let failure):
              id = recordID
              isTerminal = failure != .retryable && failure != .zoneMissing
          case .deleted:
              continue
          }
          guard isTerminal, let record = recordByIdentity[storageIdentity(id)] else { continue }
          completed.insert(record.snipID)
      }
      guard state.approvedSnipIDs.isSubset(of: completed) else { return state }
      let linkedSnipIDs = Set(current.records.map(\.snipID))
      let unapprovedDuringSeed = Set(current.snips.map(\.id)).subtracting(linkedSnipIDs)
      return CloudNamespaceStateStorage(
          phase: .active,
          excludedSnipIDs: state.excludedSnipIDs.union(unapprovedDuringSeed)
      )
  }

  nonisolated static func isDestructiveReset(_ event: CloudDatabaseEvent) -> Bool {
      switch event {
      case .zoneDeleted(_, reason: .purged),
           .zoneDeleted(_, reason: .encryptedDataReset):
          true
      default:
          false
      }
  }

  nonisolated static func hasMissingZone(
      _ batch: CloudFetchedBatch,
      textZone: CloudZoneID?
  ) -> Bool {
      batch.databaseEvents.contains { event in
          switch event {
          case .zoneDeleted(let zone, reason: .deleted):
              textZone == nil || zone == textZone
          case .failed(let zone, .zoneMissing):
              textZone == nil || zone == nil || zone == textZone
          default:
              false
          }
      } || batch.zoneEvents.contains { event in
          guard case .failed(let zone, .zoneMissing) = event else { return false }
          return textZone == nil || zone == textZone
      }
  }

  nonisolated static func hasMissingZone(
      _ batch: CloudSentBatch,
      textZone: CloudZoneID?
  ) -> Bool {
      batch.items.contains { item in
          guard case .failed(let id, .zoneMissing) = item else { return false }
          return textZone == nil || id.zone == textZone
      } || batch.databaseEvents.contains { event in
          guard case .failed(let zone, .zoneMissing) = event else { return false }
          return textZone == nil || zone == nil || zone == textZone
      } || batch.zoneEvents.contains { event in
          guard case .failed(let zone, .zoneMissing) = event else { return false }
          return textZone == nil || zone == textZone
      }
  }

  nonisolated static func sanitizedTextBatch(_ batch: CloudSyncBatch) -> CloudSyncBatch {
      switch batch {
      case .fetched(let fetched):
          return .fetched(
              CloudFetchedBatch(
                  id: fetched.id,
                  items: fetched.items.map { item in
                      guard case .record(let snapshot) = item,
                            !snapshot.assetFields.isEmpty
                      else { return item }
                      return .failed(snapshot.id, .invalidRecord)
                  },
                  databaseEvents: fetched.databaseEvents,
                  zoneEvents: fetched.zoneEvents,
                  engineState: fetched.engineState
              )
          )
      case .sent(let sent):
          return .sent(
              CloudSentBatch(
                  id: sent.id,
                  items: sent.items.map { item in
                      switch item {
                      case .saved(let snapshot) where !snapshot.assetFields.isEmpty:
                          return .failed(snapshot.id, .invalidRecord)
                      case .conflict(let id, let snapshot) where !snapshot.assetFields.isEmpty:
                          return .failed(id, .invalidRecord)
                      default:
                          return item
                      }
                  },
                  databaseEvents: sent.databaseEvents,
                  zoneEvents: sent.zoneEvents,
                  engineState: sent.engineState
              )
          )
      }
  }

  nonisolated static func blocksAutomaticRetry(
      _ data: Data?,
      phase: CloudNamespaceBootstrapPhase
  ) -> Bool {
      guard let data else { return false }
      guard let payload = CloudWirePayloadEnvelope.legacyPayload(from: data),
          let input = try? JSONDecoder().decode(RecoveryInput.self, from: payload)
      else {
          return true
      }
      if case .sent(.failed(_, .retryable)) = input { return false }
      if case .modeRetryDeletion = input { return false }
      if phase == .seeding, case .sent(.failed(_, .zoneMissing)) = input { return false }
      return true
  }

  nonisolated static func storageIdentity(
      _ id: CloudRecordID
  ) -> CloudTextStorageIdentity {
      CloudTextStorageIdentity(
          zoneName: id.zone.name,
          ownerName: id.zone.ownerName,
          recordName: id.name
      )
  }

  nonisolated static func recordID(
      _ identity: CloudTextStorageIdentity
  ) -> CloudRecordID {
      CloudRecordID(
          zone: CloudZoneID(name: identity.zoneName, ownerName: identity.ownerName),
          name: identity.recordName
      )
  }

  nonisolated static func storageValue(
      _ snapshot: CloudRecordSnapshot
  ) throws -> CloudTextFetchedValue {
      guard snapshot.assetFields.isEmpty else {
          throw CloudRecordError.unsupportedValue
      }
      let text = try CloudTextRecord(snapshot: snapshot)
      return CloudTextFetchedValue(
          identity: storageIdentity(text.id),
          snipID: text.snipID,
          text: text.text,
          schemaVersion: text.schemaVersion,
          shadowData: text.shadow.data,
          systemFields: text.shadow.systemFields
      )
  }

  nonisolated static func shadow(
      _ stored: CloudTextStorageRecord
  ) throws -> CloudRecordShadow? {
      guard let data = stored.shadowData else { return nil }
      let shadow = try CloudRecordShadow(data: data)
      guard stored.systemFields == shadow.systemFields else {
          throw CloudRecordError.invalidShadow
      }
      return shadow
  }

  nonisolated static func encode(_ input: RecoveryInput) throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return try CloudWirePayloadEnvelope(
          format: .legacyTextV1,
          payload: encoder.encode(input)
      ).encoded()
  }

  nonisolated static func recoveryInput(_ data: Data) -> RecoveryInput? {
      guard let payload = CloudWirePayloadEnvelope.legacyPayload(from: data) else { return nil }
      return try? JSONDecoder().decode(RecoveryInput.self, from: payload)
  }

  nonisolated static func recoveryInput(_ data: Data?) -> RecoveryInput? {
      data.flatMap(recoveryInput)
  }

  nonisolated static func isRetryable(_ input: RecoveryInput?) -> Bool {
      switch input {
      case .fetched(.failed(_, .retryable)), .sent(.failed(_, .retryable)),
           .database(.failed(_, .retryable)), .zone(.failed(_, .retryable)):
          true
      default:
          false
      }
  }

  nonisolated static func isModeRetryDeletion(_ input: RecoveryInput?) -> Bool {
      if case .modeRetryDeletion = input { return true }
      return false
  }

  nonisolated static func hasRetryableState(
      for identity: CloudTextStorageIdentity,
      in snapshot: CloudTextStorageSnapshot
  ) -> Bool {
      let recordID = recordID(identity)
      for event in snapshot.recoveryEvents {
          switch recoveryInput(event.payload) {
          case .sent(.failed(let id, .retryable)):
              if id == recordID { return true }
          case .fetched(.failed(let id, .retryable)):
              if id == nil || id == recordID { return true }
          case .database(.failed(_, .retryable)), .zone(.failed(_, .retryable)):
              return true
          default:
              continue
          }
      }
      return false
  }

  nonisolated static func recoveryEvent(
      _ input: RecoveryInput,
      batchID: UUID
  ) throws -> CloudRecoveryEventStorage {
      let data = try encode(input)
      return CloudRecoveryEventStorage(
          key: "\(batchID.uuidString.lowercased())-\(data.base64EncodedString())",
          payload: data
      )
  }
}
