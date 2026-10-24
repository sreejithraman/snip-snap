import AppKit
import Foundation
import SnipSnapPersistence

/// Resolve the app and its store together, including a symlinked Homebrew CLI.
struct SnipCLIApplicationLocation {
  let applicationURL: URL?
  let rootURL: URL
  let canLaunch: Bool

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
  }

  private static func info(at applicationURL: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: applicationURL.appendingPathComponent("Contents/Info.plist")),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          info["CFBundlePackageType"] as? String == "APPL" else { return nil }
    return info
  }

  func launchIfNeeded(store: SnipCLIRequestStore) async throws {
    let bundleID = applicationURL.flatMap(Self.info)?["CFBundleIdentifier"] as? String
      ?? "world.sree.snipsnap"
    let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    if try await store.activeScopeToken() != nil, isRunning || !canLaunch { return }
    guard canLaunch else { throw SnipSnapCLIError.appUnavailable }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let applicationURL {
      process.arguments = ["-g", applicationURL.path]
    } else {
      process.arguments = ["-g", "-b", "world.sree.snipsnap"]
    }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw SnipSnapCLIError.appUnavailable }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
      if try await store.activeScopeToken() != nil { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw SnipSnapCLIError.appUnavailable
  }
}
