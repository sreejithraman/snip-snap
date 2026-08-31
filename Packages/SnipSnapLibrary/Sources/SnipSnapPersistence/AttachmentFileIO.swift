import CryptoKit
import Darwin
import Foundation
import SnipSnapCore

package enum AttachmentFileIO {
  package final class RootedDirectory {
    private let descriptor: Int32

    package init(rootURL: URL) throws {
      descriptor = try AttachmentFileIO.openDirectoryNoFollow(rootURL)
    }

    private init(descriptor: Int32) {
      self.descriptor = descriptor
    }

    deinit {
      close(descriptor)
    }

    package func openDirectory(relativePath: String) throws -> RootedDirectory {
      RootedDirectory(
        descriptor: try AttachmentFileIO.openDirectoryNoFollow(
          rootDescriptor: descriptor,
          relativePath: relativePath
        )
      )
    }

    package func readRegularFile(relativePath: String) throws -> Data {
      let opened = try AttachmentFileIO.openRegularFileNoFollow(
        rootDescriptor: descriptor,
        relativePath: relativePath
      )
      defer { close(opened.descriptor) }
      return try AttachmentFileIO.readAll(descriptor: opened.descriptor)
    }

    package func copyRegularFile(
      relativePath: String,
      to destinationURL: URL,
      expectedByteCount: Int64,
      beforeFinalOpen: () throws -> Void = {}
    ) throws -> CopiedFile {
      try AttachmentFileIO.copyRegularFile(
        fromRootDescriptor: descriptor,
        relativePath: relativePath,
        to: destinationURL,
        expectedByteCount: expectedByteCount,
        beforeFinalOpen: beforeFinalOpen
      )
    }

    package func copyRegularFile(
      relativePath: String,
      to destinationURL: URL
    ) throws -> CopiedFile {
      try AttachmentFileIO.copyRegularFile(
        fromRootDescriptor: descriptor,
        relativePath: relativePath,
        to: destinationURL,
        expectedByteCount: nil,
        beforeFinalOpen: {}
      )
    }
  }

  package struct StagedSnapshot: Sendable {
    let snapshot: SnipLibraryTransferSnapshot
    let lease: SnipImportStagingLease?
  }

  package struct CopiedFile {
    package let digest: Data
    package let byteCount: Int64
  }

  package static func copyRegularFile(
    from sourceURL: URL,
    to destinationURL: URL,
    expectedByteCount: Int64
  ) throws -> CopiedFile {
    try copyRegularFile(
      fromRoot: sourceURL.deletingLastPathComponent(),
      relativePath: sourceURL.lastPathComponent,
      to: destinationURL,
      expectedByteCount: expectedByteCount
    )
  }

  package static func copyRegularFile(
    from sourceURL: URL,
    to destinationURL: URL
  ) throws -> CopiedFile {
    let root = try RootedDirectory(rootURL: sourceURL.deletingLastPathComponent())
    return try root.copyRegularFile(
      relativePath: sourceURL.lastPathComponent,
      to: destinationURL
    )
  }

  package static func copyRegularFile(
    fromRoot rootURL: URL,
    relativePath: String,
    to destinationURL: URL,
    expectedByteCount: Int64,
    beforeFinalOpen: () throws -> Void = {}
  ) throws -> CopiedFile {
    let root = try RootedDirectory(rootURL: rootURL)
    return try root.copyRegularFile(
      relativePath: relativePath,
      to: destinationURL,
      expectedByteCount: expectedByteCount,
      beforeFinalOpen: beforeFinalOpen
    )
  }

  private static func copyRegularFile(
    fromRootDescriptor rootDescriptor: Int32,
    relativePath: String,
    to destinationURL: URL,
    expectedByteCount: Int64?,
    beforeFinalOpen: () throws -> Void
  ) throws -> CopiedFile {
    let source = try openRegularFileNoFollow(
      rootDescriptor: rootDescriptor,
      relativePath: relativePath,
      beforeFinalOpen: beforeFinalOpen
    )
    defer { close(source.descriptor) }
    if let expectedByteCount, source.status.st_size != expectedByteCount {
      throw SnipLibraryError.invalidStore
    }
    let destination = open(
      destinationURL.path,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard destination >= 0 else { throw SnipLibraryError.attachmentCopyFailed }
    var shouldRemoveDestination = true
    defer {
      close(destination)
      if shouldRemoveDestination {
        try? FileManager.default.removeItem(at: destinationURL)
      }
    }
    let copied = try copySparseAndDigest(
      source: source.descriptor,
      destination: destination
    )
    if let expectedByteCount, copied.byteCount != expectedByteCount {
      throw SnipLibraryError.attachmentCopyFailed
    }
    guard fsync(destination) == 0 else { throw SnipLibraryError.attachmentCopyFailed }
    var after = stat()
    guard fstat(source.descriptor, &after) == 0,
      sameFile(before: source.status, after: after),
      after.st_size == source.status.st_size,
      copied.byteCount == Int64(after.st_size)
    else { throw SnipLibraryError.invalidStore }
    shouldRemoveDestination = false
    return CopiedFile(
      digest: copied.digest,
      byteCount: Int64(after.st_size)
    )
  }

  package static func digest(at fileURL: URL) throws -> Data {
    let opened = try openRegularFileNoFollow(
      rootURL: fileURL.deletingLastPathComponent(),
      relativePath: fileURL.lastPathComponent
    )
    defer { close(opened.descriptor) }
    return try digest(descriptor: opened.descriptor)
  }

  package static func readRegularFile(
    fromRoot rootURL: URL,
    relativePath: String
  ) throws -> Data {
    let root = try RootedDirectory(rootURL: rootURL)
    return try root.readRegularFile(relativePath: relativePath)
  }

  private static func readAll(descriptor: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      guard count >= 0 else { throw SnipLibraryError.invalidStore }
      if count == 0 { break }
      data.append(contentsOf: buffer[0 ..< count])
    }
    return data
  }

  package static func contentsEqual(_ fileURL: URL, data: Data) throws -> Bool {
    try digest(at: fileURL) == Data(SHA256.hash(data: data))
  }

  package static func contentsEqual(_ first: URL, _ second: URL) throws -> Bool {
    try digest(at: first) == digest(at: second)
  }

  package static func stagePreviewSnapshot(
    _ snapshot: SnipLibraryTransferSnapshot,
    transitionID: UUID
  ) throws -> StagedSnapshot {
    guard !snapshot.attachmentFileURLs.isEmpty else {
      return StagedSnapshot(snapshot: snapshot, lease: nil)
    }
    let stagingRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnipSnapImportPreviews", isDirectory: true)
      .appendingPathComponent(transitionID.uuidString, isDirectory: true)
    let attachmentRoot = stagingRoot.appendingPathComponent("Attachments", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: attachmentRoot,
        withIntermediateDirectories: true
      )
      let attachments = Dictionary(
        snapshot.snips.flatMap(\.attachments).map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      var stagedURLs: [UUID: URL] = [:]
      var stagedDigests: [UUID: Data] = [:]
      for (id, sourceURL) in snapshot.attachmentFileURLs {
        guard snapshot.attachmentData[id] == nil,
          let attachment = attachments[id],
          let expectedDigest = snapshot.attachmentFileDigests[id]
        else { throw SnipLibraryError.invalidStore }
        let safeName = URL(fileURLWithPath: attachment.fileName).lastPathComponent
        guard !safeName.isEmpty else { throw SnipLibraryError.invalidStore }
        let destination = attachmentRoot
          .appendingPathComponent(id.uuidString, isDirectory: true)
          .appendingPathComponent(safeName)
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        let copied = try copyRegularFile(
          from: sourceURL,
          to: destination,
          expectedByteCount: attachment.byteCount
        )
        guard copied.digest == expectedDigest else {
          throw SnipLibraryError.importChanged
        }
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o400)],
          ofItemAtPath: destination.path
        )
        stagedURLs[id] = destination
        stagedDigests[id] = copied.digest
      }
      let lease = SnipImportStagingLease(rootURL: stagingRoot) {
        try FileManager.default.removeItem(at: stagingRoot)
      }
      return StagedSnapshot(
        snapshot: SnipLibraryTransferSnapshot(
          revision: snapshot.revision,
          snips: snapshot.snips,
          lists: snapshot.lists,
          attachmentData: snapshot.attachmentData,
          attachmentFileURLs: stagedURLs,
          attachmentFileDigests: stagedDigests,
          legacyManualPositions: snapshot.legacyManualPositions,
          opaqueSyncStateDigest: snapshot.opaqueSyncStateDigest,
          opaqueSyncStatePayload: snapshot.opaqueSyncStatePayload
        ),
        lease: lease
      )
    } catch {
      try? FileManager.default.removeItem(at: stagingRoot)
      throw error
    }
  }

  private struct OpenedFile {
    let descriptor: Int32
    let status: stat
  }

  private static func openRegularFileNoFollow(
    rootURL: URL,
    relativePath: String,
    beforeFinalOpen: () throws -> Void = {}
  ) throws -> OpenedFile {
    let rootDescriptor = try openDirectoryNoFollow(rootURL)
    defer { close(rootDescriptor) }
    return try openRegularFileNoFollow(
      rootDescriptor: rootDescriptor,
      relativePath: relativePath,
      beforeFinalOpen: beforeFinalOpen
    )
  }

  private static func openRegularFileNoFollow(
    rootDescriptor: Int32,
    relativePath: String,
    beforeFinalOpen: () throws -> Void = {}
  ) throws -> OpenedFile {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw SnipLibraryError.invalidStore }
    var directory = dup(rootDescriptor)
    guard directory >= 0 else { throw SnipLibraryError.invalidStore }
    for component in components.dropLast() {
      let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      close(directory)
      guard next >= 0 else { throw SnipLibraryError.invalidStore }
      directory = next
    }
    do {
      try beforeFinalOpen()
    } catch {
      close(directory)
      throw error
    }
    let descriptor = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW)
    close(directory)
    guard descriptor >= 0 else { throw SnipLibraryError.invalidStore }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFREG
    else {
      close(descriptor)
      throw SnipLibraryError.invalidStore
    }
    return OpenedFile(descriptor: descriptor, status: status)
  }

  private static func openDirectoryNoFollow(_ directoryURL: URL) throws -> Int32 {
    let standardized = directoryURL.standardizedFileURL
    if standardized.path == "/" {
      let descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      guard descriptor >= 0 else { throw SnipLibraryError.invalidStore }
      return descriptor
    }
    let directoryName = standardized.lastPathComponent
    guard !directoryName.isEmpty,
      let resolvedPointer = realpath(
        standardized.deletingLastPathComponent().path,
        nil
      )
    else { throw SnipLibraryError.invalidStore }
    defer { free(resolvedPointer) }
    let parentPath = String(cString: resolvedPointer)
    guard parentPath.hasPrefix("/") else { throw SnipLibraryError.invalidStore }
    let parentComponents = parentPath.split(separator: "/").map(String.init)
    var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard parent >= 0 else { throw SnipLibraryError.invalidStore }
    for component in parentComponents {
      let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      close(parent)
      guard next >= 0 else { throw SnipLibraryError.invalidStore }
      parent = next
    }
    let directory = openat(parent, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    close(parent)
    guard directory >= 0 else { throw SnipLibraryError.invalidStore }
    return directory
  }

  private static func openDirectoryNoFollow(
    rootDescriptor: Int32,
    relativePath: String
  ) throws -> Int32 {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw SnipLibraryError.invalidStore }
    var directory = dup(rootDescriptor)
    guard directory >= 0 else { throw SnipLibraryError.invalidStore }
    for component in components {
      let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      close(directory)
      guard next >= 0 else { throw SnipLibraryError.invalidStore }
      directory = next
    }
    return directory
  }

  private static func digest(descriptor: Int32) throws -> Data {
    guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
      throw SnipLibraryError.attachmentCopyFailed
    }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      guard count >= 0 else { throw SnipLibraryError.attachmentCopyFailed }
      if count == 0 { break }
      hasher.update(data: Data(buffer[0 ..< count]))
    }
    return Data(hasher.finalize())
  }

  private static func copySparseAndDigest(
    source: Int32,
    destination: Int32
  ) throws -> CopiedFile {
    guard lseek(source, 0, SEEK_SET) >= 0 else {
      throw SnipLibraryError.attachmentCopyFailed
    }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    var byteCount: Int64 = 0
    while true {
      let count = read(source, &buffer, buffer.count)
      guard count >= 0 else { throw SnipLibraryError.attachmentCopyFailed }
      if count == 0 { break }
      let chunk = buffer[0 ..< count]
      hasher.update(data: Data(chunk))
      if chunk.allSatisfy({ $0 == 0 }) {
        guard lseek(destination, off_t(count), SEEK_CUR) >= 0 else {
          throw SnipLibraryError.attachmentCopyFailed
        }
      } else {
        try writeAll(chunk, to: destination)
      }
      byteCount += Int64(count)
    }
    guard ftruncate(destination, off_t(byteCount)) == 0 else {
      throw SnipLibraryError.attachmentCopyFailed
    }
    return CopiedFile(digest: Data(hasher.finalize()), byteCount: byteCount)
  }

  private static func writeAll(
    _ bytes: ArraySlice<UInt8>,
    to descriptor: Int32
  ) throws {
    try bytes.withUnsafeBytes { rawBytes in
      guard let start = rawBytes.baseAddress else { return }
      var offset = 0
      while offset < rawBytes.count {
        let count = write(
          descriptor,
          start.advanced(by: offset),
          rawBytes.count - offset
        )
        guard count > 0 else { throw SnipLibraryError.attachmentCopyFailed }
        offset += count
      }
    }
  }

  private static func sameFile(before: stat, after: stat) -> Bool {
    before.st_dev == after.st_dev
      && before.st_ino == after.st_ino
      && before.st_size == after.st_size
      && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
      && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
  }
}

extension SnipLibraryTransferPlan {
  package func attachmentContentsEqual(
    attachmentID: UUID,
    fileURL: URL
  ) throws -> Bool {
    if let bytes = attachmentData[attachmentID] {
      return try AttachmentFileIO.contentsEqual(fileURL, data: bytes)
    }
    if let expectedDigest = attachmentFileDigests[attachmentID] {
      return try AttachmentFileIO.digest(at: fileURL) == expectedDigest
    }
    throw SnipLibraryError.attachmentCopyFailed
  }
}
