import Darwin
import Foundation
import SnipSnapCore

/// Where the iOS app keeps its SwiftData stores (ADR 0031).
///
/// iOS terminates a suspended app that holds a SQLite or file lock in an App Group container
/// (`0xdead10cc`). Only the main app opens these stores (ADR 0016), so they belong in its own
/// container; the Share extension keeps using the App Group for pending imports.
public struct SnipLibraryLocation: Equatable, Sendable {
  public let storeURL: URL
  public let syncModeRootURL: URL

  public static func appGroup(_ containerURL: URL) -> Self {
    Self(
      storeURL: ShareImportStore.storeURL(in: containerURL),
      syncModeRootURL: containerURL.appendingPathComponent("SyncMode", isDirectory: true))
  }

  public static func appContainer(applicationSupportURL: URL) -> Self {
    let root = applicationSupportURL.appendingPathComponent("Snip Snap Library", isDirectory: true)
    return Self(
      storeURL: root.appendingPathComponent("Local", isDirectory: true)
        .appendingPathComponent("snips.store", isDirectory: false),
      syncModeRootURL: root.appendingPathComponent("SyncMode", isDirectory: true))
  }

  /// Moves the store and sync-mode directories here, each with one atomic rename, and returns
  /// where each one now is. A directory that cannot move stays in use where it is; the two
  /// directories do not refer to each other. An existing destination wins over the source.
  public func adopt(
    from source: SnipLibraryLocation, diagnostics: AppDiagnosticRecorder = .live
  ) -> SnipLibraryLocation {
    let storeDirectory = Self.adopt(
      source.storeURL.deletingLastPathComponent(), into: storeURL.deletingLastPathComponent(),
      diagnostics: diagnostics)
    return Self(
      storeURL: storeDirectory.appendingPathComponent(storeURL.lastPathComponent, isDirectory: false),
      syncModeRootURL: Self.adopt(
        source.syncModeRootURL, into: syncModeRootURL, diagnostics: diagnostics))
  }

  private static func adopt(
    _ source: URL, into destination: URL, diagnostics: AppDiagnosticRecorder
  ) -> URL {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: source.path) else { return destination }
    guard !fileManager.fileExists(atPath: destination.path) else {
      diagnostics.record(.failure(
        operation: "library.relocate", errorCode: "library.relocationConflict",
        visibility: .background))
      return destination
    }
    do {
      try DurableFile.createDirectory(destination.deletingLastPathComponent())
      guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try? DurableFile.syncDirectory(source.deletingLastPathComponent())
      try? DurableFile.syncDirectory(destination.deletingLastPathComponent())
      return destination
    } catch {
      diagnostics.record(.failure(
        operation: "library.relocate", error: error, visibility: .background))
      return source
    }
  }
}
