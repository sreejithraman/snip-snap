import Foundation

/// Used by the app's serial diagnostics queue and independently by offline CLI readers.
struct AppDiagnosticEventStore: Sendable {
  private struct Entry: Codable {
    let date: Date
    let line: String
    let failed: Bool
  }

  private static let unbundledNamespace = "unbundled-\(UUID().uuidString)"
  private let directoryURL: URL
  private let appVersion: String
  private let appBuild: String
  private let byteLimit: Int
  private let now: @Sendable () -> Date
  private var history: URL { directoryURL.appendingPathComponent("events.jsonl") }
  private let preference: URL

  init(
    directoryURL: URL, appVersion: String, appBuild: String,
    preferenceDirectory: URL? = nil, byteLimit: Int = 256 * 1024, now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.directoryURL = directoryURL.standardizedFileURL
    self.appVersion = Self.safeVersion(appVersion)
    self.appBuild = Self.safeVersion(appBuild)
    preference = (preferenceDirectory ?? directoryURL).appendingPathComponent("recording.json")
    self.byteLimit = byteLimit
    self.now = now
  }

  static func forBundle(
    bundleIdentifier: String?, appVersion: String, appBuild: String, bundle: Bundle? = nil
  ) -> Self {
    let directory: URL
    if let path = ProcessInfo.processInfo.environment["SNIP_SNAP_DIAGNOSTICS_DIRECTORY"],
      path.hasPrefix("/")
    {
      return Self(
        directoryURL: URL(fileURLWithPath: path, isDirectory: true),
        appVersion: appVersion, appBuild: appBuild
      )
    }
    let support = URL.applicationSupportDirectory
    let namespace = bundleIdentifier.flatMap { identifier in
      identifier.isEmpty || identifier.contains("/") || identifier == "." || identifier == ".."
        ? nil : identifier
    } ?? unbundledNamespace
    directory = support.appendingPathComponent(namespace).appendingPathComponent("SnipSnapDiagnostics")
    #if os(iOS)
      var preferenceDirectory: URL?
      // Keep the existing opt-out shared with the Share extension. Each process owns its log.
      if let group = bundle?.object(forInfoDictionaryKey: "SnipSnapAppGroupIdentifier") as? String,
        let app = bundle?.object(forInfoDictionaryKey: "SnipSnapDiagnosticsApplicationIdentifier") as? String,
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
      {
        preferenceDirectory = container.appendingPathComponent("Library/Application Support")
          .appendingPathComponent(app).appendingPathComponent("SnipSnapDiagnostics")
      }
    #else
      let preferenceDirectory: URL? = nil
    #endif
    return Self(
      directoryURL: directory, appVersion: appVersion, appBuild: appBuild,
      preferenceDirectory: preferenceDirectory
    )
  }

  static func safeVersion(_ value: String) -> String {
    guard !value.isEmpty, value.utf8.count <= 32, value.allSatisfy({ "0123456789.".contains($0) })
    else { return "unknown" }
    return value
  }

  func append(_ event: AppDiagnosticEvent, at date: Date) throws {
    guard try readRecordingEnabled() else { return }
    let entry = Entry(date: date, line: event.line, failed: event.outcome == .failed)
    let encoded = try JSONEncoder().encode(entry) + Data([10])
    guard encoded.count <= byteLimit else { return }
    var data = try read(history) ?? Data()
    if data.count + encoded.count > byteLimit {
      let start = data.endIndex - (byteLimit - encoded.count)
      if start > data.startIndex, data[data.index(before: start)] != 10 {
        data = data[start...].firstIndex(of: 10).map { Data(data.suffix(from: $0 + 1)) } ?? Data()
      } else {
        data = Data(data.suffix(from: start))
      }
    }
    data.append(encoded)
    try createDirectory(directoryURL)
    // Offline readers see a complete snapshot even during rotation.
    try data.write(to: history, options: .atomic)
  }

  func readRecordingEnabled() throws -> Bool {
    switch try read(preference) {
    case nil, Data("enabled\n".utf8): true
    case Data("disabled\n".utf8): false
    default: throw CocoaError(.fileReadCorruptFile)
    }
  }

  func setRecordingEnabled(_ enabled: Bool) throws {
    try createDirectory(preference.deletingLastPathComponent())
    try Data((enabled ? "enabled\n" : "disabled\n").utf8).write(to: preference, options: .atomic)
  }

  func readLog(
    range: AppDiagnosticExportRange, limit: Int, errorsOnly: Bool
  ) throws -> AppDiagnosticLogReport {
    guard limit > 0 else { throw POSIXError(.EINVAL) }
    let cutoff = now().addingTimeInterval(range == .last24Hours ? -86_400 : -604_800)
    let decoder = JSONDecoder()
    let matching = (try read(history) ?? Data()).split(separator: 10)
      .compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
      .filter { $0.date >= cutoff && (!errorsOnly || $0.failed) }
      .sorted { $0.date < $1.date }
    let selected = matching.suffix(limit)
    let truncated = selected.count < matching.count
    let enabled = try readRecordingEnabled()
    var text = """
      Snip Snap diagnostics
      app_version=\(appVersion) app_build=\(appBuild)
      recording_enabled=\(enabled) selected_range=\(range.rawValue)
      \(truncated ? "truncated=true\n" : "")
      """
    for entry in selected {
      text += "\(entry.date.ISO8601Format()) \(entry.line)\n"
    }
    return AppDiagnosticLogReport(text: text, returnedEvents: selected.count, truncated: truncated)
  }

  func makeShareableFile(range: AppDiagnosticExportRange) throws -> URL {
    let report = try readLog(range: range, limit: .max, errorsOnly: false)
    let directory = directoryURL.appendingPathComponent("export-\(UUID().uuidString)")
    try createDirectory(directory)
    let file = directory.appendingPathComponent("Snip-Snap-Diagnostics.txt")
    do {
      try report.text.write(to: file, atomically: true, encoding: .utf8)
      return file
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  func removeShareableFile(_ file: URL) {
    let directory = file.standardizedFileURL.deletingLastPathComponent()
    guard file.lastPathComponent == "Snip-Snap-Diagnostics.txt",
      directory.deletingLastPathComponent().path == directoryURL.path,
      isExportDirectory(directory)
    else { return }
    try? FileManager.default.removeItem(at: directory)
  }

  func clear() throws {
    let manager = FileManager.default
    let files: [URL]
    do {
      files = try manager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
    } catch CocoaError.fileReadNoSuchFile {
      return
    }
    for file in files where file.lastPathComponent == history.lastPathComponent || isExportDirectory(file) {
      try manager.removeItem(at: file)
    }
  }

  private func isExportDirectory(_ directory: URL) -> Bool {
    let name = directory.lastPathComponent
    return name.hasPrefix("export-") && UUID(uuidString: String(name.dropFirst("export-".count))) != nil
  }

  private func createDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  private func read(_ file: URL) throws -> Data? {
    do {
      return try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    }
  }
}
