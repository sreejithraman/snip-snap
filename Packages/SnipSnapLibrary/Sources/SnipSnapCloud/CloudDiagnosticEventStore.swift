import Foundation

final class CloudDiagnosticEventStore: @unchecked Sendable {
  static let live = CloudDiagnosticEventStore(
    directoryURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("SnipSnapDiagnostics", isDirectory: true),
    maxBytes: 64 * 1024,
    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown",
    appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      ?? "unknown"
  )

  private let directoryURL: URL
  private let eventsURL: URL
  private let shareURL: URL
  private let maxBytes: Int
  private let header: String
  private let lock = NSLock()

  init(directoryURL: URL, maxBytes: Int, appVersion: String, appBuild: String) {
    self.directoryURL = directoryURL
    eventsURL = directoryURL.appendingPathComponent("attachment-events.txt")
    shareURL = directoryURL.appendingPathComponent("Snip-Snap-Diagnostics.txt")
    self.maxBytes = maxBytes
    header = """
      Snip Snap diagnostics
      format=1 app_version=\(appVersion) app_build=\(appBuild)
      privacy=attachment-stage-events-only

      """
  }

  func append(_ event: String, at date: Date = Date()) {
    lock.withLock {
      do {
        try FileManager.default.createDirectory(
          at: directoryURL,
          withIntermediateDirectories: true
        )
        let line = "\(date.ISO8601Format(.iso8601(timeZone: .gmt))) \(event)\n"
        let existing = (try? String(contentsOf: eventsURL, encoding: .utf8)) ?? header
        let contents = bounded(header + eventLines(from: existing) + line)
        try contents.write(to: eventsURL, atomically: true, encoding: .utf8)
      } catch {
        // Diagnostics must never alter attachment behavior.
      }
    }
  }

  func makeShareableFile() throws -> URL {
    try lock.withLock {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      let contents = (try? String(contentsOf: eventsURL, encoding: .utf8)) ?? header
      try contents.write(to: shareURL, atomically: true, encoding: .utf8)
      return shareURL
    }
  }

  func clear() throws {
    try lock.withLock {
      for url in [eventsURL, shareURL] where FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  private func eventLines(from contents: String) -> String {
    guard let separator = contents.range(of: "\n\n") else { return contents }
    return String(contents[separator.upperBound...])
  }

  private func bounded(_ contents: String) -> String {
    guard contents.utf8.count > maxBytes else { return contents }
    var lines = eventLines(from: contents).split(separator: "\n", omittingEmptySubsequences: true)
    while !lines.isEmpty {
      let candidate = header + lines.joined(separator: "\n") + "\n"
      if candidate.utf8.count <= maxBytes { return candidate }
      lines.removeFirst()
    }
    return header
  }
}
