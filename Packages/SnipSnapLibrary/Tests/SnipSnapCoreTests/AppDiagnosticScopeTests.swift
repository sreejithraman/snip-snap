import Darwin
import Foundation
import XCTest

@testable import SnipSnapCore

final class AppDiagnosticScopeTests: XCTestCase {
  private var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  func testUnavailableBootIdentityDoesNotSuppressNewBootButStillRejectsOldSubmissions() throws {
    let store = AppDiagnosticEventStore(directoryURL: root, appVersion: "1", appBuild: "2")
    _ = try store.readRecordingEnabled()
    let timestamp = Date().timeIntervalSinceReferenceDate
    func stampData(uptime: Double, capturedAt: Double) throws -> Data {
      try JSONSerialization.data(withJSONObject: [
        "boot": "unknown", "uptime": uptime, "capturedAt": capturedAt,
      ])
    }
    let fence = try JSONSerialization.data(withJSONObject: [
      "submission": ["boot": "unknown", "uptime": 200.0, "capturedAt": timestamp - 100],
    ])
    try fence.write(to: root.appendingPathComponent("submission-fence.json"))
    let fresh = try JSONDecoder().decode(AppDiagnosticSubmissionStamp.self,
      from: stampData(uptime: 1, capturedAt: timestamp))
    let stale = try JSONDecoder().decode(AppDiagnosticSubmissionStamp.self,
      from: stampData(uptime: 150, capturedAt: timestamp - 200))
    try store.appendThrowing(.succeeded(operation: "clipboard.persist"), submitted: fresh)
    try store.appendThrowing(.succeeded(operation: "clipboard.load"), submitted: stale)
    let report = try store.readLog()
    XCTAssertEqual(report.returnedEvents, 1)
    XCTAssertTrue(report.text.contains("operation=clipboard.persist"))
    XCTAssertFalse(report.text.contains("operation=clipboard.load"))
    XCTAssertFalse(report.text.contains("boot="))
    XCTAssertFalse(report.text.contains("uptime="))
  }

  func testApplicationExportIncludesExtensionAndAppFailures() throws {
    let app = scope(bundle: "test.app")
    let share = scope(bundle: "test.app.share")
    app.recorder.record(
      .failure(operation: "app.startup", errorCode: "presentation.startup", visibility: .user))
    share.recorder.record(
      .failure(operation: "share.extension_load", errorCode: "cocoa.260", visibility: .user))
    _ = try share.readLog()
    let report = try app.readLog(range: .last7Days, limit: 200, errorsOnly: true)
    XCTAssertTrue(report.text.contains("operation=app.startup"))
    XCTAssertTrue(report.text.contains("operation=share.extension_load"))
    XCTAssertEqual(report.returnedEvents, 2)
  }

  func testUnavailableSharedControlsNeverPersistOutageEventsOrClaimPrivateRecordingTruth() async throws {
    for phase in ["off", "off-on", "on"] {
      for isExtension in [false, true] {
        let app = "test.\(phase).\(isExtension ? "extension" : "main")"
        let bundle = isExtension ? app + ".share" : app
        let controls = scope(bundle: isExtension ? app : app + ".share", app: app)
        try controls.setRecordingEnabled(phase == "on")
        let unavailable = scope(bundle: bundle, app: app, shared: false)
        XCTAssertThrowsError(try unavailable.readRecordingEnabled())
        XCTAssertThrowsError(try unavailable.readLog())
        XCTAssertThrowsError(try unavailable.snapshot())
        XCTAssertThrowsError(try unavailable.setRecordingEnabled(true))
        XCTAssertThrowsError(try unavailable.setRecordingEnabled(true, ifRevision: "unknown"))
        XCTAssertThrowsError(try unavailable.makeShareableFile())
        XCTAssertThrowsError(try unavailable.clear())
        XCTAssertThrowsError(try unavailable.clear(ifRevision: "unknown"))
        unavailable.recorder.record(.failure(
          operation: "share.extension_save", errorCode: "cocoa.513", visibility: .user))
        unavailable.recorder.record(.succeeded(operation: "app.startup"))
        let flushed = await unavailable.recorder.flush(timeout: 1)
        XCTAssertTrue(flushed)
        let prior = AppDiagnosticEventStore.storageDirectoryURL(
          applicationSupportURL: root.appendingPathComponent(bundle), bundleIdentifier: bundle,
          environment: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: prior.path),
          "Missing shared controls must not create private segments, sidecars, or queued persistence")
        if phase == "off-on" { try controls.setRecordingEnabled(true) }
        let recovered = scope(bundle: bundle, app: app)
        XCTAssertEqual(try recovered.readLog().returnedEvents, 0,
          "Neither shared Off nor Off/On may recover outage captures")
        try controls.setRecordingEnabled(true)
        recovered.recorder.record(.failure(
          operation: "share.extension_load", errorCode: "cocoa.260", visibility: .user))
        let report = try recovered.readLog()
        XCTAssertEqual(report.returnedEvents, 1)
        XCTAssertTrue(report.text.contains("operation=share.extension_load"))
        XCTAssertFalse(report.text.contains("operation=share.extension_save"))
        XCTAssertFalse(report.text.contains("operation=app.startup"))
      }
    }
  }

  func testInaccessibleSharedStoreDiscardsQueuedEventsInsteadOfReplayingAfterRepair() async throws {
    let shared = scope(bundle: "test.app")
    XCTAssertTrue(try shared.readRecordingEnabled())
    let directory = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("group.test/Library/Application Support"),
      bundleIdentifier: "test.app", environment: [:])
    let blockedLock = directory.appendingPathComponent(".lock")
    try FileManager.default.removeItem(at: blockedLock)
    try FileManager.default.createDirectory(at: blockedLock, withIntermediateDirectories: false)
    shared.recorder.record(.failure(
      operation: "share.extension_save", errorCode: "cocoa.513", visibility: .user))
    shared.recorder.record(.succeeded(operation: "app.startup"))
    XCTAssertThrowsError(try shared.readRecordingEnabled())
    try FileManager.default.removeItem(at: blockedLock)
    XCTAssertEqual(try shared.readLog().returnedEvents, 0,
      "Unavailable-control submissions must not survive as events or uncertain-write loss envelopes")
    shared.recorder.record(.failure(
      operation: "share.extension_load", errorCode: "cocoa.260", visibility: .user))
    let recovered = try shared.readLog()
    XCTAssertEqual(recovered.returnedEvents, 1)
    XCTAssertTrue(recovered.text.contains("operation=share.extension_load"))
    XCTAssertFalse(recovered.text.contains("error=diagnostics.writeFailed"))
  }

  func testReadableSharedLockContentionRetainsTheSubmissionForRetry() throws {
    let shared = scope(bundle: "test.app")
    XCTAssertTrue(try shared.readRecordingEnabled())
    let directory = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("group.test/Library/Application Support"),
      bundleIdentifier: "test.app", environment: [:])
    let held = try ScopeProcessLock(directory: directory)
    defer { held.release() }
    let start = ContinuousClock.now
    shared.recorder.record(.failure(
      operation: "share.extension_save", errorCode: "cocoa.513", visibility: .user))
    XCTAssertLessThan(start.duration(to: .now), .milliseconds(200))
    XCTAssertThrowsError(try shared.readRecordingEnabled()) { error in
      XCTAssertTrue(error is AppDiagnosticAccessError)
    }
    held.release()
    let report = try shared.readLog()
    XCTAssertEqual(report.returnedEvents, 1)
    XCTAssertTrue(report.text.contains("operation=share.extension_save"))
  }

  func testOrdinaryPrivateAndExplicitlyIsolatedScopesStillRecord() throws {
    let cases: [(String?, String?, String?, Bool)] = [
      ("test.mac", nil, nil, false), (nil, nil, nil, false),
      ("other.app", "test.app", "group.test", false),
      ("test.app.dev", nil, nil, false),
      ("test.isolated", "test.isolated", "group.test", true),
    ]
    for (index, entry) in cases.enumerated() {
      let directory = root.appendingPathComponent("private-\(index)")
      let privateScope = AppDiagnosticScope.resolve(
        bundleIdentifier: entry.0, applicationIdentifier: entry.1, appGroupIdentifier: entry.2,
        sharedContainerURL: nil, applicationSupportURL: directory,
        cachesURL: root.appendingPathComponent("cache-\(index)"),
        environment: entry.3 ? ["SNIP_SNAP_DIAGNOSTICS_DIRECTORY": directory.path] : [:],
        appVersion: "1", appBuild: "2")
      XCTAssertFalse(privateScope.sharesApplicationHistory)
      XCTAssertTrue(try privateScope.readRecordingEnabled())
      privateScope.recorder.record(.failure(
        operation: "app.startup", errorCode: "presentation.startup", visibility: .user))
      let report = try privateScope.readLog()
      XCTAssertEqual(report.returnedEvents, 1)
      XCTAssertTrue(report.text.contains("operation=app.startup"))
    }
  }

  @MainActor
  func testUnreadableSharedPreferenceKeepsSettingsUnknownUntilRetryWithoutPersistingFailures() async throws {
    let shared = scope(bundle: "test.app")
    XCTAssertTrue(try shared.readRecordingEnabled())
    let directory = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("group.test/Library/Application Support"),
      bundleIdentifier: "test.app", environment: [:])
    let preference = directory.appendingPathComponent("recording.json")
    try Data("invalid\n".utf8).write(to: preference)
    let operations = AppDiagnosticSettingsModel.Operations(
      readRecording: { try shared.readRecordingEnabled() },
      setRecording: { try shared.setRecordingEnabled($0) },
      prepareExport: { try shared.makeShareableFile(range: $0) },
      removeExport: { shared.removeShareableFile($0) }, clear: { try shared.clear() })
    let model = AppDiagnosticSettingsModel(operations: operations, diagnostics: shared.recorder)
    model.activate()
    await settle(model)
    XCTAssertNil(model.recordingEnabled)
    XCTAssertFalse(model.canPerformActions)
    XCTAssertEqual(model.notice, .readFailed)
    XCTAssertThrowsError(try shared.setRecordingEnabled(true))
    XCTAssertThrowsError(try shared.clear())
    shared.recorder.record(.failure(
      operation: "share.extension_save", errorCode: "cocoa.513", visibility: .user))
    _ = await shared.recorder.flush(timeout: 1)
    try Data("enabled\n".utf8).write(to: preference, options: .atomic)
    model.refreshRecording()
    await settle(model)
    XCTAssertEqual(model.recordingEnabled, true)
    XCTAssertTrue(model.canPerformActions)
    XCTAssertNil(model.notice)
    XCTAssertEqual(try shared.readLog().returnedEvents, 0)
    model.deactivate()
  }

  func testUpgradePreservesOwnedSegmentsCachedHistoryAndNewExtensionHistory() throws {
    let support = root.appendingPathComponent("test.app")
    let cache = root.appendingPathComponent("cache/test.app")
    let prior = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: support, bundleIdentifier: "test.app", environment: [:])
    let cached = AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: cache, bundleIdentifier: "test.app", environment: [:])
    let old = AppDiagnosticEventStore(directoryURL: prior, appVersion: "0.9", appBuild: "1")
    old.append(
      .failure(operation: "app.startup", errorCode: "presentation.startup", visibility: .user),
      at: Date().addingTimeInterval(-86_400))
    try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)
    let legacy =
      "\(Date().addingTimeInterval(-86_400).ISO8601Format()) diagnostic_event operation=backup.export outcome=failed visibility=user error=cocoa.513\n"
    try Data(legacy.utf8).write(to: cached.appendingPathComponent("diagnostic-events.txt"))
    let share = scope(bundle: "test.app.share")
    share.recorder.record(
      .failure(operation: "share.extension_load", errorCode: "cocoa.260", visibility: .user))
    _ = try share.readLog()
    let app = scope(bundle: "test.app")
    let report = try app.readLog(range: .last7Days)
    XCTAssertTrue(report.text.contains("operation=app.startup"))
    XCTAssertTrue(report.text.contains("operation=backup.export"))
    XCTAssertTrue(report.text.contains("operation=share.extension_load"))
    XCTAssertEqual(report.returnedEvents, 3)
    XCTAssertEqual(try scope(bundle: "test.app").readLog(range: .last7Days).returnedEvents, 3)
  }

  func testUnreadablePriorHistoryIsRetainedAndRetriesWithoutReplacingExtensionEvents() throws {
    let prior = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("test.app"), bundleIdentifier: "test.app",
      environment: [:])
    let old = AppDiagnosticEventStore(directoryURL: prior, appVersion: "0.9", appBuild: "1")
    old.append(
      .failure(operation: "app.startup", errorCode: "presentation.startup", visibility: .user))
    let segment = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(at: prior, includingPropertiesForKeys: nil).first {
        $0.lastPathComponent.hasPrefix("protected-")
      })
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: segment.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: segment.path)
    }
    let share = scope(bundle: "test.app.share")
    share.recorder.record(
      .failure(operation: "share.extension_load", errorCode: "cocoa.260", visibility: .user))
    _ = try share.readLog()
    let app = scope(bundle: "test.app")
    XCTAssertEqual(try app.readLog().returnedEvents, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: segment.path))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: segment.path)
    let recovered = try app.readLog()
    XCTAssertEqual(recovered.returnedEvents, 2)
    XCTAssertTrue(recovered.text.contains("operation=app.startup"))
    XCTAssertTrue(recovered.text.contains("operation=share.extension_load"))
  }

  func testRepeatedFallbackRecoveryConsumesEachFailureOnceAndKeepsSharedPreference() throws {
    let fallback = historicalScope(bundle: "test.app")
    XCTAssertFalse(fallback.sharesApplicationHistory)
    fallback.recorder.record(
      .failure(operation: "app.startup", errorCode: "presentation.startup", visibility: .user))
    _ = try fallback.readLog()
    let shared = scope(bundle: "test.app")
    XCTAssertEqual(try shared.readLog().returnedEvents, 1)

    let laterFallback = historicalScope(bundle: "test.app")
    laterFallback.recorder.record(
      .failure(operation: "clipboard.persist", errorCode: "cocoa.513", visibility: .user))
    _ = try laterFallback.readLog()
    try laterFallback.setRecordingEnabled(false)
    let prior = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("test.app"), bundleIdentifier: "test.app",
      environment: [:])
    let segment = try XCTUnwrap(FileManager.default.contentsOfDirectory(
      at: prior, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" })
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: segment.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: segment.path)
    }
    XCTAssertEqual(try shared.readLog().returnedEvents, 1)
    XCTAssertTrue(try shared.readRecordingEnabled()) // A later private opt-out is not initial adoption.
    try shared.setRecordingEnabled(false)
    try shared.setRecordingEnabled(true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: segment.path))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: segment.path)
    for _ in 0..<3 {
      let recovered = scope(bundle: "test.app")
      XCTAssertTrue(try recovered.readRecordingEnabled())
      let report = try recovered.readLog()
      let events = report.text.split(separator: "\n").filter { $0.contains(" diagnostic_event ") }
      XCTAssertEqual(report.returnedEvents, 2)
      XCTAssertEqual(events.filter { $0.contains("operation=app.startup") }.count, 1)
      XCTAssertEqual(events.filter { $0.contains("operation=clipboard.persist") }.count, 1)
      XCTAssertFalse(events.contains { $0.contains("count=") })
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: segment.path))
  }

  func testClearDiscardsLaterFallbackHistoryAfterCompletedRecoveryAndKeepsFreshSharedEvent() throws {
    let fallback = historicalScope(bundle: "test.app")
    fallback.recorder.record(
      .failure(operation: "app.startup", errorCode: "presentation.startup", visibility: .user))
    _ = try fallback.readLog()
    let shared = scope(bundle: "test.app")
    XCTAssertEqual(try shared.readLog().returnedEvents, 1)
    try shared.clear()

    let laterFallback = historicalScope(bundle: "test.app")
    laterFallback.recorder.record(
      .failure(operation: "clipboard.persist", errorCode: "cocoa.513", visibility: .user))
    XCTAssertEqual(try laterFallback.readLog().returnedEvents, 1)
    shared.recorder.record(
      .failure(operation: "share.extension_load", errorCode: "cocoa.260", visibility: .user))
    _ = try shared.readLog()
    for _ in 0..<3 {
      let report = try scope(bundle: "test.app").readLog()
      XCTAssertEqual(report.returnedEvents, 1)
      XCTAssertTrue(report.text.contains("operation=share.extension_load"))
      XCTAssertFalse(report.text.contains("operation=app.startup"))
      XCTAssertFalse(report.text.contains("operation=clipboard.persist"))
    }
    XCTAssertEqual(try laterFallback.readLog().returnedEvents, 0)
  }

  func testClearDoesNotResurrectUnreadablePriorHistoryWhenItBecomesReadable() throws {
    let prior = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("test.app"),
      bundleIdentifier: "test.app", environment: [:])
    let old = AppDiagnosticEventStore(directoryURL: prior, appVersion: "0.9", appBuild: "1")
    // A wall-clock rollback makes pre-clear evidence appear newer than the clear.
    old.append(
      .failure(operation: "app.startup", errorCode: "presentation.startup", visibility: .user),
      at: Date().addingTimeInterval(3_600))
    let segment = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(at: prior, includingPropertiesForKeys: nil).first {
        $0.lastPathComponent.hasPrefix("protected-")
      })
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: segment.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: segment.path)
    }
    let app = scope(bundle: "test.app")
    try app.clear()
    XCTAssertTrue(FileManager.default.fileExists(atPath: segment.path))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: segment.path)
    XCTAssertEqual(try app.readLog().returnedEvents, 0)
  }

  func testExtensionClearDiscardsLaterDiscoveredSourcesOnlyInItsApplicationNamespace() throws {
    let future = Date().addingTimeInterval(3_600)
    var unreadable: [URL] = []
    defer {
      for file in unreadable {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      }
    }
    for bundle in ["test.app", "test.app.dev", "other.app"] {
      let prior = AppDiagnosticEventStore.storageDirectoryURL(
        applicationSupportURL: root.appendingPathComponent(bundle), bundleIdentifier: bundle,
        environment: [:])
      let old = AppDiagnosticEventStore(directoryURL: prior, appVersion: "0.9", appBuild: "1")
      old.append(
        .failure(operation: "app.startup", errorCode: "presentation.startup", visibility: .user),
        at: future)
      let cached = AppDiagnosticEventStore.storageDirectoryURL(
        cachesURL: root.appendingPathComponent("cache/\(bundle)"), bundleIdentifier: bundle,
        environment: [:])
      try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)
      let legacy = cached.appendingPathComponent("diagnostic-events.txt")
      try Data("\(future.ISO8601Format()) diagnostic_event operation=backup.export outcome=failed visibility=user error=cocoa.513\n".utf8)
        .write(to: legacy)
      if bundle == "test.app" {
        let segment = try XCTUnwrap(FileManager.default.contentsOfDirectory(
          at: prior, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" })
        unreadable = [segment, legacy]
        for file in unreadable {
          try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        }
      }
    }
    // This instance knows only the extension's old sandbox, not the main app's sources.
    let share = scope(bundle: "test.app.share")
    try share.clear()
    share.recorder.record(
      .failure(operation: "share.extension_load", errorCode: "cocoa.260", visibility: .user))
    _ = try share.readLog()
    let app = scope(bundle: "test.app")
    XCTAssertEqual(try app.readLog().returnedEvents, 1)
    for file in unreadable {
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    app.recorder.record(.succeeded(operation: "clipboard.persist", byteCount: 42))
    _ = try app.readLog()
    let report = try scope(bundle: "test.app").readLog()
    XCTAssertEqual(report.returnedEvents, 2)
    XCTAssertTrue(report.text.contains("operation=share.extension_load"))
    XCTAssertTrue(report.text.contains("operation=clipboard.persist"))
    XCTAssertFalse(report.text.contains("operation=app.startup"))
    XCTAssertFalse(report.text.contains("operation=backup.export"))
    for file in unreadable { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
    for bundle in ["test.app.dev", "other.app"] {
      let independent = try scope(bundle: bundle, app: bundle).readLog()
      XCTAssertEqual(independent.returnedEvents, 2)
      XCTAssertTrue(independent.text.contains("operation=app.startup"))
      XCTAssertTrue(independent.text.contains("operation=backup.export"))
    }
  }

  func testPriorRecordingOffPreferenceGovernsNewExtensionWrites() throws {
    let prior = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("test.app"), bundleIdentifier: "test.app",
      environment: [:])
    let old = AppDiagnosticEventStore(directoryURL: prior, appVersion: "0.9", appBuild: "1")
    old.append(
      .failure(operation: "app.startup", errorCode: "presentation.startup", visibility: .user))
    try old.setRecordingEnabled(false)
    let app = scope(bundle: "test.app")
    XCTAssertFalse(try app.readRecordingEnabled())
    let share = scope(bundle: "test.app.share")
    share.recorder.record(
      .failure(operation: "share.extension_save", errorCode: "cocoa.513", visibility: .user))
    _ = try share.readLog()
    let report = try app.readLog()
    XCTAssertTrue(report.text.contains("operation=app.startup"))
    XCTAssertFalse(report.text.contains("operation=share.extension_save"))
  }

  func testOwnedHealthMigratesWhileRecordingOffAndClearDiscardsLaterUnreadableHealth() throws {
    let prior = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("test.app"), bundleIdentifier: "test.app",
      environment: [:])
    var policy = AppDiagnosticRetentionPolicy()
    policy.contextCount = 0
    let old = AppDiagnosticEventStore(
      directoryURL: prior, policy: policy, appVersion: "0.9", appBuild: "1")
    old.append(.syncSnapshot(scope: .transport, pendingEvents: 3))
    old.append(.succeeded(operation: "sync.fetch"))
    old.append(.succeeded(operation: "sync.send"))
    old.append(.failure(operation: "app.startup", errorCode: "presentation.startup", visibility: .user))
    try old.setRecordingEnabled(false)
    let health = prior.appendingPathComponent("diagnostic-sync-health.txt")
    let unsafe = "\(Date().ISO8601Format()) diagnostic_event operation=sync.fetch outcome=succeeded visibility=background path=/private/customer.txt\n"
    let handle = try FileHandle(forWritingTo: health)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(unsafe.utf8))
    try handle.close()
    for _ in 0..<2 {
      let app = scope(bundle: "test.app")
      XCTAssertFalse(try app.readRecordingEnabled())
      let report = try app.readLog()
      XCTAssertEqual(report.returnedEvents, 4)
      XCTAssertTrue(report.text.contains("diagnostic_sync_latest operation=sync.snapshot"))
      XCTAssertTrue(report.text.contains("pending_events=3"))
      for operation in ["sync.fetch", "sync.send"] {
        XCTAssertTrue(report.text.contains("diagnostic_sync_last_success operation=\(operation)"))
      }
      XCTAssertFalse(report.text.contains("customer"))
      XCTAssertFalse(report.text.contains("path="))
    }
    let app = scope(bundle: "test.app")
    try app.clear()
    try old.setRecordingEnabled(true)
    old.append(.succeeded(operation: "sync.send"), at: Date().addingTimeInterval(3_600))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: health.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: health.path)
    }
    XCTAssertEqual(try app.readLog().returnedEvents, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: health.path))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: health.path)
    let cleared = try scope(bundle: "test.app").readLog()
    XCTAssertEqual(cleared.returnedEvents, 0)
    XCTAssertFalse(cleared.text.contains("diagnostic_sync_"))
    XCTAssertFalse(try app.readRecordingEnabled())
    XCTAssertFalse(FileManager.default.fileExists(atPath: health.path))
  }

  func testOwnedHealthRetriesUnreadableFilesMergesTimestampsAndConsumesHealthOnlySources() throws {
    let prior = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("test.app"), bundleIdentifier: "test.app",
      environment: [:])
    let sharedDirectory = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("group.test/Library/Application Support"),
      bundleIdentifier: "test.app", environment: [:])
    var policy = AppDiagnosticRetentionPolicy()
    policy.contextCount = 0
    let now = Date()
    let destinationDate = now.addingTimeInterval(-10)
    let sharedStore = AppDiagnosticEventStore(
      directoryURL: sharedDirectory, policy: policy, appVersion: "1", appBuild: "2")
    sharedStore.append(.syncSnapshot(scope: .transport, pendingEvents: 99), at: destinationDate)
    sharedStore.append(.succeeded(operation: "sync.fetch"), at: destinationDate)
    try sharedStore.setRecordingEnabled(false)
    let old = AppDiagnosticEventStore(
      directoryURL: prior, policy: policy, appVersion: "0.9", appBuild: "1")
    let older = now.addingTimeInterval(-20)
    old.append(.syncSnapshot(scope: .transport, pendingEvents: 3), at: older)
    old.append(.succeeded(operation: "sync.send"), at: now.addingTimeInterval(-30))
    let sourceHealth = prior.appendingPathComponent("diagnostic-sync-health.txt")
    let destinationHealth = sharedDirectory.appendingPathComponent("diagnostic-sync-health.txt")
    let offset = ISO8601DateFormatter()
    offset.timeZone = TimeZone(secondsFromGMT: 3_600)
    try String(contentsOf: sourceHealth, encoding: .utf8)
      .replacingOccurrences(of: older.ISO8601Format(), with: offset.string(from: older))
      .write(to: sourceHealth, atomically: true, encoding: .utf8)
    let sourceSegments = try FileManager.default.contentsOfDirectory(
      at: prior, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
    defer {
      for file in [sourceHealth, destinationHealth] {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sourceHealth.path)
    let app = scope(bundle: "test.app")
    XCTAssertEqual(try app.readLog().returnedEvents, 2)
    for file in sourceSegments { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceHealth.path)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: destinationHealth.path)
    XCTAssertEqual(try app.readLog().returnedEvents, 4)
    XCTAssertTrue(FileManager.default.fileExists(atPath: sourceHealth.path))
    for file in sourceSegments { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationHealth.path)
    let merged = try scope(bundle: "test.app").readLog()
    XCTAssertEqual(merged.returnedEvents, 4, "Retry must deduplicate the already copied records")
    let transport = try XCTUnwrap(merged.text.split(separator: "\n").first {
      $0.contains(" diagnostic_sync_latest ") && $0.contains("scope=transport")
    })
    XCTAssertTrue(transport.contains("pending_events=99"), "Compare instants, not offset timestamp text")
    XCTAssertTrue(merged.text.contains("diagnostic_sync_last_success operation=sync.fetch"))
    XCTAssertTrue(merged.text.contains("diagnostic_sync_last_success operation=sync.send"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sourceHealth.path))

    old.append(.syncSnapshot(scope: .records, pendingEvents: 7), at: now.addingTimeInterval(-8 * 86_400))
    XCTAssertEqual(try old.readLog().returnedEvents, 0)
    let healthOnly = try app.readLog()
    XCTAssertEqual(healthOnly.returnedEvents, 4)
    let records = try XCTUnwrap(healthOnly.text.split(separator: "\n").first {
      $0.contains(" diagnostic_sync_latest ") && $0.contains("scope=records")
    })
    XCTAssertTrue(records.contains("pending_events=7"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sourceHealth.path))
    old.append(.syncSnapshot(scope: .transport, pendingEvents: 5), at: destinationDate)
    for _ in 0..<2 {
      let report = try scope(bundle: "test.app").readLog()
      XCTAssertEqual(report.returnedEvents, 5)
      let tied = try XCTUnwrap(report.text.split(separator: "\n").first {
        $0.contains(" diagnostic_sync_latest ") && $0.contains("scope=transport")
      })
      XCTAssertTrue(tied.contains("pending_events=99"), "Keep destination health when timestamps tie")
      XCTAssertFalse(try app.readRecordingEnabled())
    }
  }

  func testRecordingOnNeverLetsLegacyConsumeDeferredOwnedHealth() throws {
    for failure in ["source", "destination", "oversized"] {
      let bundle = "test.\(failure)"
      let prior = AppDiagnosticEventStore.storageDirectoryURL(
        applicationSupportURL: root.appendingPathComponent(bundle), bundleIdentifier: bundle,
        environment: [:])
      let destination = AppDiagnosticEventStore.storageDirectoryURL(
        applicationSupportURL: root.appendingPathComponent("group.test/Library/Application Support"),
        bundleIdentifier: bundle, environment: [:])
      var policy = AppDiagnosticRetentionPolicy()
      policy.contextCount = 0
      let now = Date()
      let sharedStore = AppDiagnosticEventStore(
        directoryURL: destination, policy: policy, appVersion: "1", appBuild: "2")
      sharedStore.append(.syncSnapshot(scope: .transport, pendingEvents: 99), at: now)
      sharedStore.append(.succeeded(operation: "sync.fetch"), at: now)
      try sharedStore.setRecordingEnabled(true)
      let old = AppDiagnosticEventStore(
        directoryURL: prior, policy: policy, appVersion: "0.9", appBuild: "1")
      old.append(.syncSnapshot(scope: .transport, pendingEvents: 3), at: now.addingTimeInterval(-20))
      old.append(.succeeded(operation: "sync.send"), at: now.addingTimeInterval(-30))
      let sourceHealth = prior.appendingPathComponent("diagnostic-sync-health.txt")
      let destinationHealth = destination.appendingPathComponent("diagnostic-sync-health.txt")
      let sourceData = try Data(contentsOf: sourceHealth)
      let destinationData = try Data(contentsOf: destinationHealth)
      let segments = try FileManager.default.contentsOfDirectory(
        at: prior, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
      XCTAssertFalse(segments.isEmpty)
      defer {
        for file in [sourceHealth, destinationHealth] {
          try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
      }
      if failure == "oversized" {
        try (sourceData + Data(repeating: 32, count: 4_096) + Data([10])).write(to: sourceHealth)
      } else {
        let file = failure == "source" ? sourceHealth : destinationHealth
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
      }
      let app = scope(bundle: bundle, app: bundle)
      let deferred = try app.readLog()
      XCTAssertEqual(deferred.returnedEvents, failure == "destination" ? 4 : 2)
      XCTAssertTrue(FileManager.default.fileExists(atPath: sourceHealth.path))
      for file in segments { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationHealth.path)
      XCTAssertEqual(try Data(contentsOf: destinationHealth), destinationData,
        "Legacy migration must not overwrite newer or unreadable destination health")
      if failure == "oversized" {
        try app.clear()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceHealth.path))
      }
      try sourceData.write(to: sourceHealth, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceHealth.path)
      let repaired = try scope(bundle: bundle, app: bundle).readLog()
      if failure == "oversized" {
        XCTAssertEqual(repaired.returnedEvents, 0)
        XCTAssertFalse(repaired.text.contains("diagnostic_sync_"))
        app.recorder.record(.succeeded(operation: "sync.fetch"))
        XCTAssertEqual(try app.readLog().returnedEvents, 1)
      } else {
        XCTAssertEqual(repaired.returnedEvents, 4)
        let transport = try XCTUnwrap(repaired.text.split(separator: "\n").first {
          $0.contains(" diagnostic_sync_latest ") && $0.contains("scope=transport")
        })
        XCTAssertTrue(transport.contains("pending_events=99"))
        XCTAssertTrue(repaired.text.contains("diagnostic_sync_last_success operation=sync.send"))
      }
      XCTAssertTrue(try app.readRecordingEnabled())
      XCTAssertFalse(FileManager.default.fileExists(atPath: sourceHealth.path))
    }
  }

  func testOwnedHealthExclusionPreservesLegacyCacheHealthAndPriorTextLogs() throws {
    let prior = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("test.app"), bundleIdentifier: "test.app",
      environment: [:])
    let old = AppDiagnosticEventStore(directoryURL: prior, appVersion: "0.9", appBuild: "1")
    old.append(.syncSnapshot(scope: .transport, pendingEvents: 3))
    let timestamp = Date().ISO8601Format()
    let priorEvents = prior.appendingPathComponent("diagnostic-events.txt")
    let attachments = prior.appendingPathComponent("attachment-events.txt")
    try "\(timestamp) diagnostic_event operation=backup.export outcome=failed visibility=user error=cocoa.513\n"
      .write(to: priorEvents, atomically: true, encoding: .utf8)
    try "\(timestamp) attachment_download stage=cache_install outcome=failed error=cocoa.260\n"
      .write(to: attachments, atomically: true, encoding: .utf8)
    let cache = AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: root.appendingPathComponent("cache/test.app"), bundleIdentifier: "test.app",
      environment: [:])
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let cacheHealth = cache.appendingPathComponent("diagnostic-sync-health.txt")
    try "\(timestamp) diagnostic_event operation=sync.send outcome=succeeded visibility=background\n"
      .write(to: cacheHealth, atomically: true, encoding: .utf8)
    for _ in 0..<2 {
      let app = scope(bundle: "test.app")
      XCTAssertTrue(try app.readRecordingEnabled())
      let report = try app.readLog()
      XCTAssertEqual(report.returnedEvents, 3)
      XCTAssertTrue(report.text.contains("diagnostic_sync_latest operation=sync.snapshot"))
      XCTAssertTrue(report.text.contains("diagnostic_sync_last_success operation=sync.send"))
      XCTAssertTrue(report.text.contains("operation=backup.export"))
      XCTAssertTrue(report.text.contains("attachment_download stage=cache_install outcome=failed"))
    }
    for file in [priorEvents, attachments, cacheHealth] {
      XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
  }

  func testImportedHealthDefersAllSourcesUntilDestinationMergeAndRetriesUnreadableCache() throws {
    let prior = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("test.app"), bundleIdentifier: "test.app",
      environment: [:])
    let destination = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("group.test/Library/Application Support"),
      bundleIdentifier: "test.app", environment: [:])
    var policy = AppDiagnosticRetentionPolicy()
    policy.contextCount = 0
    let now = Date()
    let store = AppDiagnosticEventStore(
      directoryURL: destination, policy: policy, appVersion: "1", appBuild: "2")
    store.append(.syncSnapshot(scope: .transport, pendingEvents: 99), at: now)
    store.append(.succeeded(operation: "sync.fetch"), at: now)
    try store.setRecordingEnabled(true)
    try FileManager.default.createDirectory(at: prior, withIntermediateDirectories: true)
    let plainLog = prior.appendingPathComponent("diagnostic-events.txt")
    try "\(now.addingTimeInterval(-20).ISO8601Format()) diagnostic_event operation=sync.fetch outcome=succeeded visibility=background\n"
      .write(to: plainLog, atomically: true, encoding: .utf8)
    let cache = AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: root.appendingPathComponent("cache/test.app"), bundleIdentifier: "test.app",
      environment: [:])
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let cacheHealth = cache.appendingPathComponent("diagnostic-sync-health.txt")
    try "\(now.addingTimeInterval(-30).ISO8601Format()) diagnostic_event operation=sync.send outcome=succeeded visibility=background\n"
      .write(to: cacheHealth, atomically: true, encoding: .utf8)
    let health = destination.appendingPathComponent("diagnostic-sync-health.txt")
    let original = try Data(contentsOf: health)
    defer {
      for file in [health, cacheHealth] {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: health.path)
    let app = scope(bundle: "test.app")
    XCTAssertThrowsError(try app.readLog())
    XCTAssertTrue(FileManager.default.fileExists(atPath: plainLog.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: cacheHealth.path))
    XCTAssertTrue(try legacyCacheMarkers(in: destination).isEmpty)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: health.path)
    XCTAssertEqual(try Data(contentsOf: health), original)
    guard FileManager.default.fileExists(atPath: plainLog.path),
      FileManager.default.fileExists(atPath: cacheHealth.path) else { return }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cacheHealth.path)
    let partial = try app.readLog()
    XCTAssertEqual(partial.returnedEvents, 3)
    XCTAssertFalse(FileManager.default.fileExists(atPath: plainLog.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: cacheHealth.path))
    XCTAssertTrue(try legacyCacheMarkers(in: destination).isEmpty)
    XCTAssertEqual(try Data(contentsOf: health), original)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheHealth.path)
    for _ in 0..<2 {
      let repaired = try scope(bundle: "test.app").readLog()
      XCTAssertEqual(repaired.returnedEvents, 3)
      XCTAssertTrue(repaired.text.contains("pending_events=99"))
      XCTAssertTrue(repaired.text.contains("\(now.ISO8601Format()) diagnostic_sync_last_success operation=sync.fetch"))
      XCTAssertTrue(repaired.text.contains("diagnostic_sync_last_success operation=sync.send"))
      XCTAssertTrue(try app.readRecordingEnabled())
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: cacheHealth.path))
    XCTAssertFalse(try legacyCacheMarkers(in: destination).isEmpty)
  }

  func testImportedHealthSelectsNewestAcrossLogsSidecarsAndDestination() throws {
    let prior = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("test.app"), bundleIdentifier: "test.app",
      environment: [:])
    let destination = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("group.test/Library/Application Support"),
      bundleIdentifier: "test.app", environment: [:])
    var policy = AppDiagnosticRetentionPolicy()
    policy.contextCount = 0
    let now = Date()
    let store = AppDiagnosticEventStore(
      directoryURL: destination, policy: policy, appVersion: "1", appBuild: "2")
    store.append(.syncSnapshot(scope: .transport, pendingEvents: 99), at: now.addingTimeInterval(-10))
    store.append(.succeeded(operation: "sync.fetch"), at: now.addingTimeInterval(-10))
    try store.setRecordingEnabled(true)
    try FileManager.default.createDirectory(at: prior, withIntermediateDirectories: true)
    let newestCache = now.addingTimeInterval(-1).ISO8601Format()
    let newestSend = now.addingTimeInterval(-2).ISO8601Format()
    let plainLog = prior.appendingPathComponent("diagnostic-events.txt")
    try [
      "\(now.addingTimeInterval(-20).ISO8601Format()) diagnostic_event operation=sync.fetch outcome=succeeded visibility=background",
      "\(newestSend) diagnostic_event operation=sync.send outcome=succeeded visibility=background",
      "\(now.addingTimeInterval(-3).ISO8601Format()) diagnostic_event operation=sync.snapshot outcome=succeeded visibility=background scope=records pending_events=7",
    ].joined(separator: "\n").write(to: plainLog, atomically: true, encoding: .utf8)
    let cache = AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: root.appendingPathComponent("cache/test.app"), bundleIdentifier: "test.app",
      environment: [:])
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let cacheHealth = cache.appendingPathComponent("diagnostic-sync-health.txt")
    try [
      "\(now.addingTimeInterval(-20).ISO8601Format()) diagnostic_event operation=sync.snapshot outcome=succeeded visibility=background scope=transport pending_events=3",
      "\(now.addingTimeInterval(-30).ISO8601Format()) diagnostic_event operation=sync.fetch outcome=succeeded visibility=background",
      "\(newestCache) diagnostic_event operation=sync.fetch outcome=succeeded visibility=background",
      "\(now.addingTimeInterval(-30).ISO8601Format()) diagnostic_event operation=sync.send outcome=succeeded visibility=background",
      "\(now.addingTimeInterval(-20).ISO8601Format()) diagnostic_event operation=sync.snapshot outcome=succeeded visibility=background scope=records pending_events=6",
      "\(newestCache) diagnostic_event operation=sync.snapshot outcome=succeeded visibility=background scope=records pending_events=8",
    ].joined(separator: "\n").write(to: cacheHealth, atomically: true, encoding: .utf8)
    for _ in 0..<2 {
      let report = try scope(bundle: "test.app").readLog()
      XCTAssertEqual(report.returnedEvents, 5)
      XCTAssertTrue(report.text.contains("\(newestCache) diagnostic_sync_last_success operation=sync.fetch"))
      XCTAssertTrue(report.text.contains("\(newestSend) diagnostic_sync_last_success operation=sync.send"))
      let transport = try XCTUnwrap(report.text.split(separator: "\n").first {
        $0.contains(" diagnostic_sync_latest ") && $0.contains("scope=transport")
      })
      XCTAssertTrue(transport.contains("pending_events=99"))
      let records = try XCTUnwrap(report.text.split(separator: "\n").first {
        $0.contains(" diagnostic_sync_latest ") && $0.contains("scope=records")
      })
      XCTAssertTrue(records.contains("pending_events=8"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: plainLog.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: cacheHealth.path))
  }

  func testTruncatedCacheHealthStaysPendingUntilClearAndLiveCaptureKeepsAppendOrder() throws {
    let destination = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("group.test/Library/Application Support"),
      bundleIdentifier: "test.app", environment: [:])
    let store = AppDiagnosticEventStore(directoryURL: destination, appVersion: "1", appBuild: "2")
    let now = Date()
    store.append(.syncSnapshot(scope: .transport, pendingEvents: 99), at: now)
    try store.setRecordingEnabled(true)
    let cache = AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: root.appendingPathComponent("cache/test.app"), bundleIdentifier: "test.app",
      environment: [:])
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let cacheHealth = cache.appendingPathComponent("diagnostic-sync-health.txt")
    let row = "\(now.addingTimeInterval(-10).ISO8601Format()) diagnostic_event operation=sync.fetch outcome=succeeded visibility=background\n"
    try (Data(row.utf8) + Data(repeating: 32, count: 64 * 1_024) + Data([10])).write(to: cacheHealth)
    let app = scope(bundle: "test.app")
    let truncated = try app.readLog()
    XCTAssertEqual(truncated.returnedEvents, 1)
    XCTAssertTrue(truncated.text.contains("diagnostic_sync_last_success operation=sync.fetch"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: cacheHealth.path))
    XCTAssertTrue(try legacyCacheMarkers(in: destination).isEmpty)
    try app.clear()
    XCTAssertFalse(FileManager.default.fileExists(atPath: cacheHealth.path))
    try Data(row.utf8).write(to: cacheHealth)
    let cleared = try scope(bundle: "test.app").readLog()
    XCTAssertEqual(cleared.returnedEvents, 0)
    XCTAssertFalse(cleared.text.contains("diagnostic_sync_"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: cacheHealth.path))
    XCTAssertFalse(try legacyCacheMarkers(in: destination).isEmpty)
    app.recorder.record(.succeeded(operation: "sync.send"))
    XCTAssertEqual(try app.readLog().returnedEvents, 1)
    let earlierLiveDate = now.addingTimeInterval(-3_600)
    store.append(.succeeded(operation: "sync.send"), at: earlierLiveDate)
    let live = try app.readLog()
    XCTAssertEqual(live.returnedEvents, 2)
    XCTAssertTrue(live.text.contains("\(earlierLiveDate.ISO8601Format()) diagnostic_sync_last_success operation=sync.send"))
    XCTAssertFalse(live.text.contains("diagnostic_sync_last_success operation=sync.fetch"))
    XCTAssertTrue(try app.readRecordingEnabled())
  }

  func testUpgradeAdoptsPriorRecordingOffBeforeExportingEarlyExtensionEvents() throws {
    let prior = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent("test.app"),
      bundleIdentifier: "test.app", environment: [:])
    let old = AppDiagnosticEventStore(directoryURL: prior, appVersion: "0.9", appBuild: "1")
    old.append(
      .failure(operation: "app.startup", errorCode: "presentation.startup", visibility: .user))
    try old.setRecordingEnabled(false)
    // The extension cannot inspect the previous main-app sandbox before the app
    // runs its upgrade migration. Its early evidence must not escape an old opt-out.
    let share = scope(bundle: "test.app.share")
    share.recorder.record(
      .failure(operation: "share.extension_save", errorCode: "cocoa.513", visibility: .user))
    _ = try share.readLog()
    let app = scope(bundle: "test.app")
    XCTAssertFalse(try app.readRecordingEnabled())
    let report = try app.readLog()
    XCTAssertTrue(report.text.contains("operation=app.startup"))
    XCTAssertFalse(report.text.contains("operation=share.extension_save"))
  }

  func testMacDevGroupAndExplicitTestScopesStayIsolated() throws {
    let release = scope(bundle: "test.app")
    release.recorder.record(
      .failure(operation: "app.startup", errorCode: "presentation.startup", visibility: .user))
    _ = try release.readLog()
    let dev = scope(bundle: "test.app.dev", app: "test.app.dev")
    XCTAssertEqual(try dev.readLog().returnedEvents, 0)
    let otherGroup = scope(bundle: "test.app", group: "group.other")
    XCTAssertEqual(try otherGroup.readLog().returnedEvents, 0)
    let mac = AppDiagnosticScope.resolve(
      bundleIdentifier: "test.app", applicationIdentifier: nil, appGroupIdentifier: nil,
      sharedContainerURL: nil, applicationSupportURL: root.appendingPathComponent("mac"),
      cachesURL: root.appendingPathComponent("mac-cache"), environment: [:], appVersion: "1",
      appBuild: "2")
    XCTAssertFalse(mac.sharesApplicationHistory)
    XCTAssertEqual(try mac.readLog().returnedEvents, 0)
    let isolated = AppDiagnosticScope.resolve(
      bundleIdentifier: "test.app", applicationIdentifier: "test.app",
      appGroupIdentifier: "group.test",
      sharedContainerURL: root.appendingPathComponent("group.test"),
      applicationSupportURL: root.appendingPathComponent("test.app"),
      cachesURL: root.appendingPathComponent("cache/test.app"),
      environment: [
        "SNIP_SNAP_DIAGNOSTICS_DIRECTORY": root.appendingPathComponent("isolated").path
      ], appVersion: "1", appBuild: "2")
    XCTAssertFalse(isolated.sharesApplicationHistory)
    XCTAssertEqual(try isolated.readLog().returnedEvents, 0)
    try dev.clear()
    try isolated.clear()
    XCTAssertEqual(try release.readLog().returnedEvents, 1)
  }

  func testSharedHistoryUsesOneBudgetAndExcludesBackupsAndCleansItsExport() throws {
    var policy = AppDiagnosticRetentionPolicy()
    policy.historyBytes = 16_384
    policy.protectedBytes = 4_096
    policy.segmentBytes = 2_048
    policy.contextCount = 0
    let directory = root.appendingPathComponent("bounded")
    let app = AppDiagnosticScope(
      store: AppDiagnosticEventStore(
        directoryURL: directory, policy: policy, appVersion: "1", appBuild: "2"))
    let share = AppDiagnosticScope(
      store: AppDiagnosticEventStore(
        directoryURL: directory, policy: policy, appVersion: "1", appBuild: "2"))
    share.recorder.record(
      .failure(operation: "share.extension_load", errorCode: "cocoa.260", visibility: .user))
    _ = try share.readLog()
    for batch in 0..<10 {
      for index in 0..<32 {
        app.recorder.record(
          .succeeded(operation: "clipboard.persist", byteCount: Int64(batch * 32 + index)))
      }
      _ = try app.readLog()
    }
    let report = try share.readLog()
    XCTAssertTrue(report.text.contains("operation=share.extension_load"))
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey])
    let bytes = try files.filter { $0.lastPathComponent != ".lock" }.reduce(0) {
      try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    XCTAssertLessThanOrEqual(bytes, policy.historyBytes)
    XCTAssertTrue(
      try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    )
    let export = try app.makeShareableFile()
    app.removeShareableFile(export)
    XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
  }

  func testClearAndDisableInvalidateBufferedExtensionEventsAcrossInstances() throws {
    for clear in [true, false] {
      let directory = root.appendingPathComponent(clear ? "clear" : "off")
      let store = AppDiagnosticEventStore(
        directoryURL: directory, appVersion: "1", appBuild: "2", lockTimeout: 0.01)
      let writer = AppDiagnosticWriter(store: store, scheduleRetry: { _, _ in })
      let share = AppDiagnosticScope(store: store, writer: writer)
      let app = AppDiagnosticScope(
        store: AppDiagnosticEventStore(directoryURL: directory, appVersion: "1", appBuild: "2"))
      let held = try ScopeProcessLock(directory: directory)
      share.recorder.record(
        .failure(operation: "share.extension_save", errorCode: "cocoa.513", visibility: .user))
      XCTAssertThrowsError(try share.readLog())
      held.release()
      if clear {
        try app.clear()
      } else {
        try app.setRecordingEnabled(false)
        try app.setRecordingEnabled(true)
      }
      XCTAssertEqual(try share.readLog().returnedEvents, 0)
      share.recorder.record(
        .failure(operation: "share.extension_load", errorCode: "cocoa.260", visibility: .user))
      XCTAssertEqual(try share.readLog().returnedEvents, 1)
    }
  }

  func testDrainPreservesBoundedOverflowAccounting() async throws {
    var policy = AppDiagnosticRetentionPolicy()
    policy.contextCount = 0
    let directory = root.appendingPathComponent("overflow")
    let store = AppDiagnosticEventStore(
      directoryURL: directory, policy: policy, appVersion: "1", appBuild: "2", lockTimeout: 0.01)
    let writer = AppDiagnosticWriter(store: store, capacity: 4)
    let scope = AppDiagnosticScope(store: store, writer: writer)
    let held = try ScopeProcessLock(directory: directory)
    for index in 0..<1_000 {
      scope.recorder.record(.succeeded(operation: "clipboard.persist", byteCount: Int64(index)))
    }
    scope.recorder.record(
      .failure(operation: "share.extension_save", errorCode: "cocoa.513", visibility: .user))
    held.release()
    let drained = await scope.recorder.flush(timeout: 1)
    XCTAssertTrue(drained)
    let report = try scope.readLog()
    XCTAssertTrue(report.text.contains("operation=share.extension_save"))
    XCTAssertTrue(report.text.contains("error=diagnostics.routineOverflow"))
    let count = report.text.split(separator: "\n").filter { $0.contains(" diagnostic_event ") }
      .reduce(0) { sum, line in
        let field = line.split(separator: " ").first { $0.hasPrefix("count=") }
        return sum + (field.flatMap { Int($0.dropFirst(6)) } ?? 1)
      }
    XCTAssertEqual(count, 1_001)
    XCTAssertLessThanOrEqual(report.returnedEvents, 14)
  }

  func testBoundedDrainTimesOutCancelsAndThenPersistsAfterContention() async throws {
    let directory = root.appendingPathComponent("drain")
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", lockTimeout: 0.02)
    let scope = AppDiagnosticScope(store: store)
    let held = try ScopeProcessLock(directory: directory)
    scope.recorder.record(
      .failure(operation: "share.extension_load", errorCode: "cocoa.260", visibility: .user))
    let start = ContinuousClock.now
    let drained = await scope.recorder.flush(timeout: 0.08)
    XCTAssertFalse(drained)
    XCTAssertLessThan(start.duration(to: .now), .milliseconds(300))
    let cancelled = Task { await scope.recorder.flush(timeout: 2) }
    cancelled.cancel()
    let cancellationResult = await cancelled.value
    XCTAssertFalse(cancellationResult)
    held.release()
    let recovered = await scope.recorder.flush(timeout: 1)
    XCTAssertTrue(recovered)
    XCTAssertTrue(try scope.readLog().text.contains("operation=share.extension_load"))
  }

  func testDrainedShortLivedProcessPersistsBeforeExit() throws {
    let isolated = root.appendingPathComponent("process-drained")
    let held = try ScopeProcessLock(directory: isolated)
    defer { held.release() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [
      "-XCTest", "SnipSnapCoreTests.AppDiagnosticScopeTests/testShortLivedProcessFixture",
      Bundle(for: Self.self).bundleURL.path,
    ]
    var environment = Self.fixtureEnvironment
    environment["SNIP_SNAP_DIAGNOSTICS_DIRECTORY"] = isolated.path
    environment["SNIP_SNAP_DIAGNOSTIC_PROCESS_FIXTURE"] = "drained"
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    Thread.sleep(forTimeInterval: 0.3)
    held.release()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertTrue(
      String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains(
        "fixture_submitted"))
    let store = AppDiagnosticEventStore(directoryURL: isolated, appVersion: "1", appBuild: "2")
    XCTAssertTrue(try store.readLog().text.contains("operation=share.extension_load"))
  }

  func testStoppedProcessLosesAnUndrainedBufferedFailure() throws {
    let isolated = root.appendingPathComponent("process")
    let held = try ScopeProcessLock(directory: isolated)
    defer { held.release() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [
      "-XCTest", "SnipSnapCoreTests.AppDiagnosticScopeTests/testShortLivedProcessFixture",
      Bundle(for: Self.self).bundleURL.path,
    ]
    var environment = Self.fixtureEnvironment
    environment["SNIP_SNAP_DIAGNOSTICS_DIRECTORY"] = isolated.path
    environment["SNIP_SNAP_DIAGNOSTIC_PROCESS_FIXTURE"] = "undrained"
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertTrue(
      String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains(
        "fixture_submitted"))
    held.release()
    let store = AppDiagnosticEventStore(directoryURL: isolated, appVersion: "1", appBuild: "2")
    XCTAssertEqual(try store.readLog().returnedEvents, 0)
  }

  func testShortLivedProcessFixture() async throws {
    guard ProcessInfo.processInfo.environment["SNIP_SNAP_DIAGNOSTIC_PROCESS_FIXTURE"] != nil else {
      return
    }
    AppDiagnosticRecorder.live.record(
      .failure(operation: "share.extension_load", errorCode: "cocoa.260", visibility: .user))
    try FileHandle.standardOutput.write(contentsOf: Data("fixture_submitted\n".utf8))
    if ProcessInfo.processInfo.environment["SNIP_SNAP_DIAGNOSTIC_PROCESS_FIXTURE"] == "drained" {
      let persisted = await AppDiagnosticRecorder.live.flush(timeout: 1.5)
      _exit(persisted ? 0 : 2)
    }
    _exit(0)
  }

  private static var fixtureEnvironment: [String: String] {
    let allowed: Set<String> = [
      "PATH", "HOME", "TMPDIR", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
      "DYLD_FALLBACK_FRAMEWORK_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
    ]
    return ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
  }

  @MainActor
  private func settle(_ model: AppDiagnosticSettingsModel) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while model.isBusy, ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertFalse(model.isBusy)
  }

  private func legacyCacheMarkers(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("migration-cache-") && $0.pathExtension == "complete" }
  }

  /// Models private history written by an older build, before shared capture policy.
  private func historicalScope(bundle: String) -> AppDiagnosticScope {
    let directory = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: root.appendingPathComponent(bundle), bundleIdentifier: bundle,
      environment: [:])
    return AppDiagnosticScope(store: AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2"))
  }

  private func scope(
    bundle: String, app: String = "test.app", group: String = "group.test", shared: Bool = true
  )
    -> AppDiagnosticScope
  {
    AppDiagnosticScope.resolve(
      bundleIdentifier: bundle, applicationIdentifier: app, appGroupIdentifier: group,
      sharedContainerURL: shared ? root.appendingPathComponent(group) : nil,
      applicationSupportURL: root.appendingPathComponent(bundle),
      cachesURL: root.appendingPathComponent("cache/\(bundle)"), environment: [:],
      appVersion: "1", appBuild: "2")
  }
}

private final class ScopeProcessLock {
  private let process = Process()
  private let input = Pipe()
  init(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    process.environment = ["PATH": "/usr/bin:/bin"]
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      "-c",
      "import fcntl,sys; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('r',flush=True); sys.stdin.readline()",
      directory.appendingPathComponent(".lock").path,
    ]
    let ready = Pipe()
    process.standardOutput = ready
    process.standardInput = input
    try process.run()
    guard try ready.fileHandleForReading.read(upToCount: 1) == Data("r".utf8) else {
      throw CocoaError(.fileReadUnknown)
    }
  }
  func release() {
    guard process.isRunning else { return }
    try? input.fileHandleForWriting.write(contentsOf: Data([10]))
    process.waitUntilExit()
  }
  deinit { release() }
}
