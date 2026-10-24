import AppKit
import Foundation
import SnipSnapPersistence

struct SnipCLIAppProcess: Sendable {
  let pid: Int32
  let launchDate: Date
  let applicationURL: URL
}

struct SnipCLIApplicationRuntime: Sendable {
  var applications: @Sendable (String) async -> [SnipCLIAppProcess]
  var launch: @Sendable (URL?, String) async throws -> Void
  var wait: @Sendable () async throws -> Void

  static let live = Self(
    applications: { bundleID in
      NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).compactMap {
        guard !$0.isTerminated, let date = $0.launchDate, let url = $0.bundleURL else { return nil }
        return SnipCLIAppProcess(pid: $0.processIdentifier, launchDate: date, applicationURL: url)
      }
    },
    launch: { applicationURL, bundleID in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = applicationURL.map { ["-g", $0.path] } ?? ["-g", "-b", bundleID]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { throw SnipSnapCLIError.appUnavailable }
    },
    wait: { try await Task.sleep(for: .milliseconds(50)) }
  )
}

/// Resolve the app and its store together, including a symlinked Homebrew CLI.
struct SnipCLIApplicationLocation {
  let applicationURL: URL?
  let rootURL: URL
  let canLaunch: Bool
  private let allowsUnhostedStore: Bool

  init(
    executableURL: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) throws {
    if let explicit = environment["SNIP_SNAP_APP_PATH"], !explicit.isEmpty {
      let url = URL(fileURLWithPath: explicit).standardizedFileURL
      guard explicit.hasPrefix("/"), Self.info(at: url) != nil else {
        throw SnipSnapCLIError.usage("SNIP_SNAP_APP_PATH must name an existing app bundle using an absolute path.")
      }
      applicationURL = url
    } else {
      var candidate = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
      var found: URL?
      while candidate.path != "/" {
        if candidate.pathExtension == "app", Self.info(at: candidate) != nil {
          found = candidate
          break
        }
        candidate.deleteLastPathComponent()
      }
      applicationURL = found
    }
    let info = applicationURL.flatMap(Self.info)
    if let path = LocalSnipStorePaths.storePathOverride(environment: environment, infoDictionary: info) {
      rootURL = URL(fileURLWithPath: path).deletingLastPathComponent()
    } else {
      rootURL = LocalSnipStorePaths(storeURL: SwiftDataSnipLibrary.defaultStoreURL()).rootDirectory
    }
    // An arbitrary store override must never cause the production app to launch.
    let embeddedPath = info?["SnipSnapDevelopmentStorePath"] as? String
    let overridden = environment["SNIP_SNAP_STORE_PATH"].flatMap { $0.isEmpty ? nil : $0 }
    canLaunch = environment["SNIP_SNAP_CLI_NO_LAUNCH"] != "1"
      && (overridden == nil || embeddedPath == overridden)
    allowsUnhostedStore = applicationURL == nil && overridden != nil
      && environment["SNIP_SNAP_CLI_NO_LAUNCH"] == "1"
  }

  private static func info(at applicationURL: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: applicationURL.appendingPathComponent("Contents/Info.plist")),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          info["CFBundlePackageType"] as? String == "APPL" else { return nil }
    return info
  }

  func launchIfNeeded(
    store: SnipCLIRequestStore, runtime: SnipCLIApplicationRuntime = .live,
    timeout: Duration = .seconds(10)
  ) async throws -> SnipCLIAppReadiness? {
    let bundleID = applicationURL.flatMap(Self.info)?["CFBundleIdentifier"] as? String
      ?? "world.sree.snipsnap"
    func currentReadiness() async throws -> SnipCLIAppReadiness? {
      guard let ready = try await store.appReadiness() else { return nil }
      if let applicationURL,
        ready.instance.applicationPath != applicationURL.resolvingSymlinksInPath().standardizedFileURL.path {
        return nil
      }
      let applications = await runtime.applications(bundleID)
      guard applications.contains(where: {
        $0.pid == ready.instance.pid && $0.launchDate == ready.instance.launchDate
          && $0.applicationURL.resolvingSymlinksInPath().standardizedFileURL.path == ready.instance.applicationPath
      }) else { return nil }
      return ready
    }
    if let ready = try await currentReadiness() { return ready }
    // Standalone, explicitly isolated test hosts retain their existing scope-only seam.
    // A bundled CLI always requires its current app, even with automatic launch disabled.
    if allowsUnhostedStore, try await store.appReadiness() == nil,
      try await store.activeScopeToken() != nil { return nil }
    guard canLaunch else { throw SnipSnapCLIError.appUnavailable }
    try await runtime.launch(applicationURL, bundleID)
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if let ready = try await currentReadiness() { return ready }
      try await runtime.wait()
    }
    throw SnipSnapCLIError.appUnavailable
  }
}
