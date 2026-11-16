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
      for alternative in namespace.alternatives {
        try alternative.image.value?.validate(blobs: value.blobs)
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

