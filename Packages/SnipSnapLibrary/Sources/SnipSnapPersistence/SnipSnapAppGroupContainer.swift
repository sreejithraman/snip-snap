import Foundation

public struct SnipSnapAppGroupContainer: Equatable, Sendable {
  public static let infoDictionaryKey = "SnipSnapAppGroupIdentifier"

  public let identifier: String
  public let url: URL

  public var cloudAttachmentCacheRootURL: URL {
    Self.cloudAttachmentCacheRootURL(in: url)
  }

  public static func cloudAttachmentCacheRootURL(in containerRootURL: URL) -> URL {
    cloudAttachmentCacheRootURL(
      inCachesDirectory: containerRootURL
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Caches", isDirectory: true)
    )
  }

  public static func cloudAttachmentCacheRootURL(inCachesDirectory cachesDirectory: URL) -> URL {
    cachesDirectory
      .appendingPathComponent("SnipSnap", isDirectory: true)
      .appendingPathComponent("CloudAttachments", isDirectory: true)
  }

  public static func resolve(
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) -> SnipSnapAppGroupContainer? {
    resolve(
      appGroupIdentifier: bundle.object(forInfoDictionaryKey: infoDictionaryKey) as? String,
      resolveURL: { fileManager.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    )
  }

  package static func resolve(
    appGroupIdentifier: String?,
    resolveURL: (String) -> URL?
  ) -> SnipSnapAppGroupContainer? {
    guard let identifier = appGroupIdentifier?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !identifier.isEmpty,
      let url = resolveURL(identifier)
    else { return nil }
    return SnipSnapAppGroupContainer(identifier: identifier, url: url)
  }
}
