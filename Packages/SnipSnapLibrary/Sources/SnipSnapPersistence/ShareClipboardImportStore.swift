import Darwin
import Foundation
import SnipSnapCore

/// A separate inbox keeps clipboard shares out of the saved-snips import path.
public actor ShareClipboardImportStore {
  private let paths: ShareImportPaths
  private let pendingRoot: URL
  private var isImporting = false

  public init(sharedRootURL: URL) {
    paths = ShareImportPaths(rootURL: sharedRootURL)
    pendingRoot = sharedRootURL.appendingPathComponent("Share/ClipboardImports", isDirectory: true)
  }

  public func save(
    _ request: ShareImportRequest,
    richTextRepresentations: [ClipboardRepresentation] = []
  ) async throws -> ShareImportSaveResult {
    try DurableFile.createDirectory(pendingRoot)
    let intake = paths.intakeDirectory(requestID: request.requestID)
    let ready = pendingRoot.appendingPathComponent("\(request.requestID.uuidString).ready", isDirectory: true)
    if FileManager.default.fileExists(atPath: ready.path) {
      _ = try readRequest(in: ready)
      return .pending(requestID: request.requestID)
    }
    for attachment in request.attachments {
      _ = try paths.attachmentURL(attachment, in: intake)
    }
    try DurableFile.createDirectory(intake)
    let envelope = Envelope(request: request, richTextRepresentations: richTextRepresentations)
    try DurableFile.write(JSONEncoder().encode(envelope), to: intake.appendingPathComponent("clipboard.json"))
    try DurableFile.syncDirectory(intake)
    guard Darwin.rename(intake.path, ready.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try DurableFile.syncDirectory(pendingRoot)
    try DurableFile.syncDirectory(paths.intakeRootURL)
    return .pending(requestID: request.requestID)
  }

  /// The receiver must persist the entry and copy its files before returning.
  /// Use requestID for idempotency: a crash after persistence can replay a request.
  /// Throwing retains the request and all files for the next foreground import.
  public func importPending(
    using receive: @Sendable (ShareImportRequest, [URL]) async throws -> Void
  ) async -> ShareImportSummary {
    await importPendingWithRepresentations { request, urls, _ in
      try await receive(request, urls)
    }
  }

  public func importPendingWithRepresentations(
    using receive: @Sendable (ShareImportRequest, [URL], [ClipboardRepresentation]) async throws -> Void
  ) async -> ShareImportSummary {
    guard !isImporting else { return ShareImportSummary(imported: 0, failed: 0) }
    isImporting = true
    defer { isImporting = false }
    var imported = 0
    var failed = 0
    var cleanupFailures = 0
    for directory in readyDirectories() {
      do {
        try Task.checkCancellation()
        let envelope = try readRequest(in: directory)
        let request = envelope.request
        let urls = try request.attachments.map { try paths.attachmentURL($0, in: directory) }
        try await receive(request, urls, envelope.richTextRepresentations)
        imported += 1
        do {
          try FileManager.default.removeItem(at: directory)
          try DurableFile.syncDirectory(pendingRoot)
        } catch {
          cleanupFailures += 1
        }
      } catch {
        failed += 1
      }
    }
    return ShareImportSummary(imported: imported, failed: failed, cleanupFailures: cleanupFailures)
  }

  public func pendingImportCount() -> Int { readyDirectories().count }

  private struct Envelope: Codable {
    let request: ShareImportRequest
    let richTextRepresentations: [ClipboardRepresentation]
  }

  private func readRequest(in directory: URL) throws -> Envelope {
    guard isValidReadyDirectory(directory) else { throw ShareImportError.invalidStaging }
    let data = try Data(contentsOf: directory.appendingPathComponent("clipboard.json"))
    let envelope: Envelope
    if let stored = try? JSONDecoder().decode(Envelope.self, from: data) {
      envelope = stored
    } else {
      envelope = Envelope(request: try JSONDecoder().decode(ShareImportRequest.self, from: data),
        richTextRepresentations: [])
    }
    let request = envelope.request
    guard directory.deletingPathExtension().lastPathComponent == request.requestID.uuidString else {
      throw ShareImportError.invalidStaging
    }
    for attachment in request.attachments {
      _ = try paths.attachmentURL(attachment, in: directory)
    }
    return envelope
  }

  private func readyDirectories() -> [URL] {
    let directories = (try? FileManager.default.contentsOfDirectory(
      at: pendingRoot,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    return directories.filter(isValidReadyDirectory).sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func isValidReadyDirectory(_ directory: URL) -> Bool {
    guard directory.pathExtension == "ready",
      UUID(uuidString: directory.deletingPathExtension().lastPathComponent) != nil,
      directory.standardizedFileURL.deletingLastPathComponent() == pendingRoot.standardizedFileURL,
      let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
      values.isDirectory == true, values.isSymbolicLink != true
    else { return false }
    return directory.resolvingSymlinksInPath().standardizedFileURL
      == pendingRoot.resolvingSymlinksInPath().appendingPathComponent(directory.lastPathComponent).standardizedFileURL
  }
}
