import Darwin
import Foundation

/// The installed variant is never an importable saved-version file.
struct FailedEnableEvidenceFile {
  let root: URL
  private static let magic = Data("SSFE1\n".utf8)

  var directory: URL { root.appendingPathComponent("failed-enable-evidence", isDirectory: true) }
  func url(_ sourceID: UUID) -> URL {
    directory.appendingPathComponent("\(FailedEnableEncoding.uuid(sourceID)).bundle")
  }

  func read(_ sourceID: UUID) throws -> FailedEnableInstalledEvidence? {
    let location = url(sourceID)
    guard FileManager.default.fileExists(atPath: location.path) else { return nil }
    return try decode(Data(contentsOf: location), sourceID: sourceID)
  }

  func update(
    _ sourceID: UUID,
    _ change: (FailedEnableInstalledEvidence?) throws -> FailedEnableInstalledEvidence
  ) throws {
    try DurableFile.createDirectory(directory)
    let lock = try SnipStoreFileLock(url: url(sourceID).appendingPathExtension("lock"))
    defer { withExtendedLifetime(lock) {} }
    let before = try read(sourceID)
    var next = try change(before)
    next.namespaces = try next.namespaces.map { (try FailedEnableEncoding.json($0.binding), $0) }
      .sorted { $0.0.lexicographicallyPrecedes($1.0) }.map { $0.1 }
    let revision = try before.map { try FailedEnableEncoding.revision($0.sequence) } ?? 0
    guard revision < UInt64.max else { throw FailedEnableEvidenceError.unsupported }
    next.sequence = String(revision + 1)
    try validate(next, sourceID: sourceID)
    let payload = try FailedEnableEncoding.json(next)
    var count = UInt64(payload.count).bigEndian
    var framed = Self.magic
    withUnsafeBytes(of: &count) { framed.append(contentsOf: $0) }
    framed.append(FailedEnableEncoding.checksum(payload))
    framed.append(payload)
    let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try framed.write(to: temporary, options: .withoutOverwriting)
    try DurableFile.applyDataProtection(to: temporary)
    try DurableFile.syncFile(temporary)
    guard Darwin.rename(temporary.path, url(sourceID).path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    do {
      try DurableFile.syncDirectory(directory)
    } catch {
      // Rereading disambiguates bytes; the failed synchronization still withholds effects.
      _ = try? read(sourceID)
      throw error
    }
    guard try read(sourceID) == next else { throw FailedEnableEvidenceError.changed }
  }

  private func decode(_ bytes: Data, sourceID: UUID) throws -> FailedEnableInstalledEvidence {
    guard bytes.count >= 46, bytes.prefix(6) == Self.magic else {
      throw FailedEnableEvidenceError.unsupported
    }
    let count = bytes[6..<14].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    guard count == UInt64(bytes.count - 46) else { throw FailedEnableEvidenceError.unsupported }
    let payload = Data(bytes.dropFirst(46))
    guard FailedEnableEncoding.checksum(payload) == Data(bytes[14..<46]) else {
      throw FailedEnableEvidenceError.unavailable
    }
    let value = try JSONDecoder().decode(FailedEnableInstalledEvidence.self, from: payload)
    // Closed canonical encoding also rejects duplicate/unknown keys and omitted nullable keys.
    guard try FailedEnableEncoding.json(value) == payload else {
      throw FailedEnableEvidenceError.unsupported
    }
    try validate(value, sourceID: sourceID)
    return value
  }

  private func validate(_ value: FailedEnableInstalledEvidence, sourceID: UUID) throws {
    func requireDigest(_ value: String) throws {
      guard value.count == 64, value.allSatisfy({ "0123456789abcdef".contains($0) }) else {
        throw FailedEnableEvidenceError.unsupported
      }
    }
    guard value.version == 1, value.purpose == .installedEvidence,
      value.sourceStoreID == FailedEnableEncoding.uuid(sourceID),
      Set(value.namespaces.map(\.binding)).count == value.namespaces.count
    else { throw FailedEnableEvidenceError.unsupported }
    _ = try FailedEnableEncoding.revision(value.sequence)
    _ = try FailedEnableEncoding.revision(value.continuity.sourceRevision)
    try requireDigest(value.continuity.activationDigest)
    try requireDigest(value.continuity.sourceDigest)
    for (hash, bytes) in value.blobs {
      guard FailedEnableEncoding.digest(bytes) == hash else { throw FailedEnableEvidenceError.unavailable }
    }
    var captureIDs: Set<String> = []
    var ordinals: Set<UInt64> = []
    var issueIDs: Set<String> = []
    var outputIDs: Set<String> = []
    var existingIDs: Set<String> = []
    for group in value.namespaces {
      let images = group.captures.flatMap(\.records).compactMap(\.source.value)
        + group.reviews.compactMap(\.local.image.value)
      for image in images {
        existingIDs.insert(image.reference.domainID)
        if case .snip(let snip) = image {
          existingIDs.insert(snip.requestID)
          existingIDs.formUnion(snip.attachments.map(\.id))
        }
      }
    }
    for namespace in value.namespaces {
      let binding = try namespace.binding.domain
      guard FailedEnableBinding(binding) == namespace.binding else { throw FailedEnableEvidenceError.unsupported }
      for capture in namespace.captures {
        _ = try FailedEnableEncoding.uuid(capture.id)
        _ = try FailedEnableEncoding.uuid(capture.freeze.id)
        _ = try FailedEnableEncoding.uuid(capture.transitionID)
        _ = try FailedEnableEncoding.uuid(capture.candidateStoreID)
        _ = try FailedEnableEncoding.revision(capture.freeze.sourceRevision)
        try requireDigest(capture.sourceDigest)
        try requireDigest(capture.preparationDigest)
        let ordinal = try FailedEnableEncoding.revision(capture.ordinal)
        guard captureIDs.insert(capture.id).inserted, ordinals.insert(ordinal).inserted,
          Set(capture.records.map(\.reference)).count == capture.records.count,
          capture.records.map(\.reference.sortKey) == capture.records.map(\.reference.sortKey).sorted(),
          capture.seenRequestIDs == Array(Set(capture.seenRequestIDs)).sorted()
        else { throw FailedEnableEvidenceError.unsupported }
        for id in capture.seenRequestIDs { _ = try FailedEnableEncoding.uuid(id) }
        for record in capture.records {
          _ = try record.reference.domain
          if let digest = record.preparation.baseDigest.value { try requireDigest(digest) }
          if let digest = record.preparation.fetchedDigest.value { try requireDigest(digest) }
          if let image = record.source.value {
            guard image.reference == record.reference else { throw FailedEnableEvidenceError.unsupported }
            try image.validate(blobs: value.blobs)
          }
        }
      }
      var alternativeIDs: Set<String> = []
      for alternative in namespace.alternatives {
        _ = try FailedEnableEncoding.uuid(alternative.id)
        _ = try alternative.reference.domain
        guard alternativeIDs.insert(alternative.id).inserted,
          alternative.image.value != nil || alternative.opaqueHistoricalBytes.value != nil,
          alternative.attachmentHashes == Array(Set(alternative.attachmentHashes)).sorted() else {
          throw FailedEnableEvidenceError.unsupported
        }
        if let image = alternative.image.value {
          guard image.reference == alternative.reference else { throw FailedEnableEvidenceError.unsupported }
          try image.validate(blobs: value.blobs)
        }
        for hash in alternative.attachmentHashes {
          try requireDigest(hash)
          guard value.blobs[hash] != nil else { throw FailedEnableEvidenceError.unavailable }
        }
      }
      let reviewKeys = namespace.reviews.map { $0.reference.sortKey + "|" + $0.id }
      guard reviewKeys == reviewKeys.sorted() else { throw FailedEnableEvidenceError.unsupported }
      for review in namespace.reviews {
        _ = try FailedEnableEncoding.uuid(review.id)
        _ = try review.reference.domain
        _ = try FailedEnableEncoding.revision(review.local.sourceRevision)
        try requireDigest(review.issueDigest)
        try requireDigest(review.local.sourceDigest)
        guard issueIDs.insert(review.id).inserted,
          review.local.sourceStoreID == value.sourceStoreID,
          Set(review.earlierAlternativeIDs).count == review.earlierAlternativeIDs.count,
          Set(review.earlierAlternativeIDs).isSubset(of: Set(namespace.alternatives.map(\.id))) else {
          throw FailedEnableEvidenceError.unsupported
        }
        if let image = review.local.image.value {
          guard image.reference == review.reference else { throw FailedEnableEvidenceError.unsupported }
          try image.validate(blobs: value.blobs)
        }
        if let identity = review.identity.value {
          guard namespace.binding.zones.contains(where: {
            $0.owner == identity.owner && $0.name == identity.zone
          }), !identity.name.isEmpty else { throw FailedEnableEvidenceError.unsupported }
        }
        switch review.server.state {
        case .value:
          guard let observed = review.server.observation.value,
            let digest = review.server.acceptedRevisionDigest.value else {
            throw FailedEnableEvidenceError.unsupported
          }
          try requireDigest(digest)
          _ = try FailedEnableEncoding.uuid(observed.candidateStoreID)
          _ = try FailedEnableEncoding.revision(observed.namespaceRevision)
          _ = try FailedEnableEncoding.revision(observed.localRevision)
        case .deleted, .unknown, .unavailable:
          guard review.server.observation.value == nil,
            review.server.acceptedRevisionDigest.value == nil else {
            throw FailedEnableEvidenceError.unsupported
          }
        }
        guard let decision = review.decision.value else { continue }
        let allowedFields: Set<String> = ["isDone", "pinnedAt", "placement", "source", "text"]
        guard Set(decision.fieldMask).count == decision.fieldMask.count,
          Set(decision.fieldMask) == allowedFields,
          decision.fieldMask == decision.fieldMask.sorted(),
          decision.selectedImage.value == review.local.image.value,
          review.local.membership == .present,
          case .snip(let selected)? = decision.selectedImage.value,
          selected.attachments.allSatisfy({ $0.availability.kind == .embedded }),
          decision.resolvedAlternativeIDs.isEmpty, review.earlierAlternativeIDs.isEmpty else {
          throw FailedEnableEvidenceError.unsupported
        }
        try decision.selectedImage.value?.validate(blobs: value.blobs)
        switch decision.choice {
        case .useDevice:
          guard review.server.state == .value, decision.outputIDs.isEmpty else {
            throw FailedEnableEvidenceError.unsupported
          }
        case .recoverAsNew:
          guard review.server.state == .deleted, decision.outputIDs.count == 1,
            let map = decision.outputIDs.first, map.original == review.reference,
            map.output.kind == .snip, let requestID = map.requestID.value,
            Set(map.attachments.map(\.originalID)) == Set(selected.attachments.map(\.id)),
            map.attachments.count == selected.attachments.count else {
            throw FailedEnableEvidenceError.unsupported
          }
          _ = try map.output.domain
          _ = try FailedEnableEncoding.uuid(requestID)
          let ids = [map.output.domainID, requestID] + map.attachments.map(\.newID)
          for id in ids {
            _ = try FailedEnableEncoding.uuid(id)
            guard !existingIDs.contains(id), outputIDs.insert(id).inserted else {
              throw FailedEnableEvidenceError.unsupported
            }
          }
        default: throw FailedEnableEvidenceError.unsupported
        }
      }
    }
    for transfer in value.transfers {
      _ = try FailedEnableEncoding.uuid(transfer.sourceStoreID)
      _ = try FailedEnableEncoding.uuid(transfer.destinationStoreID)
      try requireDigest(transfer.planDigest)
      try requireDigest(transfer.dormantDigest)
      for image in transfer.outputs { try image.validate(blobs: value.blobs) }
    }
  }
}

