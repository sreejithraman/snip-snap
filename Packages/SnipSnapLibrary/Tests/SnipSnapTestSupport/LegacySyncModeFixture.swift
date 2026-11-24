import Foundation

/// Writes sync-mode state that only earlier builds produced, so tests can start from it.
public enum LegacySyncModeFixture {
  /// Turns a store listed in `activation.json` into the read-only `.recovery` copy that builds
  /// before keep-local made of a library when they adopted another sync generation. Reopen the
  /// persistence afterwards.
  public static func makeRecoveryCopy(storeID: UUID, inSyncModeRoot root: URL) throws {
    let directory = try storeDirectory(storeID: storeID, inSyncModeRoot: root) { store in
      store["lifecycle"] = "recovery"
    }
    try markReadOnly(storeDirectory: directory, quarantined: true)
  }

  /// Writes the marker files that earlier builds left beside a retired store's SwiftData files.
  public static func markReadOnly(storeDirectory: URL, quarantined: Bool = false) throws {
    try Data("1".utf8).write(to: storeDirectory.appendingPathComponent(".snipsnap-read-only-recovery"))
    if quarantined {
      try Data("1".utf8).write(
        to: storeDirectory.appendingPathComponent(".snipsnap-recovery-quarantine-complete")
      )
    }
  }

  /// The store's directory, after `edit` rewrites its manifest entry.
  @discardableResult
  public static func storeDirectory(
    storeID: UUID,
    inSyncModeRoot root: URL,
    edit: (inout [String: Any]) -> Void = { _ in }
  ) throws -> URL {
    let manifestURL = root.appendingPathComponent("activation.json")
    var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
      as? [String: Any] ?? [:]
    var stores = manifest["stores"] as? [[String: Any]] ?? []
    guard let index = stores.firstIndex(where: {
      ($0["id"] as? String).flatMap(UUID.init(uuidString:)) == storeID
    }), let relativeRoot = stores[index]["relativeRoot"] as? String
    else { throw CocoaError(.fileNoSuchFile) }
    edit(&stores[index])
    manifest["stores"] = stores
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
    return root.appendingPathComponent(relativeRoot, isDirectory: true)
  }
}
