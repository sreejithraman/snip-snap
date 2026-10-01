import Foundation
import XCTest

@testable import SnipSnapCore

final class AppDiagnosticsTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
      try FileManager.default.removeItem(at: temporaryDirectory)
    }
  }

  func testNormalDevDiagnosticsStayWithBundleAcrossStoreOverridesAndRelaunch() throws {
    let cachesURL = temporaryDirectory.appendingPathComponent("Caches", isDirectory: true)
    let expected = cachesURL.appendingPathComponent("org.example.snipsnap.dev1", isDirectory: true)
      .appendingPathComponent("SnipSnapDiagnostics", isDirectory: true)
    let firstLaunchDirectory = AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: cachesURL,
      bundleIdentifier: "org.example.snipsnap.dev1",
      environment: [
        "SNIP_SNAP_STORE_PATH": temporaryDirectory.appendingPathComponent("first-library/items.json").path,
      ]
    )
    let changedStoreDirectory = AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: cachesURL,
      bundleIdentifier: "org.example.snipsnap.dev1",
      environment: [
        "SNIP_SNAP_STORE_PATH": temporaryDirectory.appendingPathComponent("other-library/items.json").path,
      ]
    )
    let ordinaryRelaunchDirectory = AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: cachesURL,
      bundleIdentifier: "org.example.snipsnap.dev1",
      environment: [:]
    )
    let firstStore = AppDiagnosticEventStore(
      directoryURL: firstLaunchDirectory, maxBytes: 4_096, appVersion: "1", appBuild: "2"
    )
    firstStore.append(.syncSnapshot(scope: .transport, environment: .development, pendingEvents: 2))

    XCTAssertEqual(firstLaunchDirectory, expected)
    XCTAssertEqual(changedStoreDirectory, expected)
    XCTAssertEqual(ordinaryRelaunchDirectory, expected)
    for directory in [changedStoreDirectory, ordinaryRelaunchDirectory] {
      let reopenedStore = AppDiagnosticEventStore(
        directoryURL: directory, maxBytes: 4_096, appVersion: "1", appBuild: "2"
      )
      let export = try String(contentsOf: reopenedStore.makeShareableFile(), encoding: .utf8)
      XCTAssertTrue(export.contains("diagnostic_sync_latest"))
      XCTAssertTrue(export.contains("pending_events=2"))
    }
    let relaunchedStore = AppDiagnosticEventStore(
      directoryURL: ordinaryRelaunchDirectory, maxBytes: 4_096, appVersion: "1", appBuild: "2"
    )
    try relaunchedStore.clear()
    let clearedExport = try String(contentsOf: firstStore.makeShareableFile(), encoding: .utf8)
    XCTAssertFalse(clearedExport.contains("diagnostic_sync_"))
  }

  func testDevAndReleaseDiagnosticsHaveSeparateExportsAndClearing() throws {
    let cachesURL = temporaryDirectory.appendingPathComponent("Caches", isDirectory: true)
    let releaseDirectory = AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: cachesURL,
      bundleIdentifier: "org.example.snipsnap",
      isolatedDirectoryPath: nil
    )
    let devDirectory = AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: cachesURL,
      bundleIdentifier: "org.example.snipsnap.dev1",
      isolatedDirectoryPath: nil
    )
    let releaseStore = AppDiagnosticEventStore(
      directoryURL: releaseDirectory, maxBytes: 4_096, appVersion: "1", appBuild: "2"
    )
    let devStore = AppDiagnosticEventStore(
      directoryURL: devDirectory, maxBytes: 4_096, appVersion: "1", appBuild: "2"
    )
    releaseStore.append(.syncSnapshot(scope: .transport, environment: .production, pendingUploads: 3))
    releaseStore.append(.succeeded(operation: "sync.send"))
    devStore.append(.syncSnapshot(scope: .transport, environment: .development, pendingEvents: 2))

    let releaseExport = try String(contentsOf: releaseStore.makeShareableFile(), encoding: .utf8)
    let devExport = try String(contentsOf: devStore.makeShareableFile(), encoding: .utf8)

    XCTAssertNotEqual(releaseDirectory, devDirectory)
    XCTAssertTrue(releaseExport.contains("environment=production"))
    XCTAssertFalse(releaseExport.contains("environment=development"))
    XCTAssertTrue(devExport.contains("environment=development"))
    XCTAssertFalse(devExport.contains("environment=production"))
    XCTAssertFalse(releaseExport.contains("org.example.snipsnap"))
    XCTAssertFalse(devExport.contains("org.example.snipsnap.dev1"))

    try devStore.clear()
    let retainedReleaseExport = try String(contentsOf: releaseStore.makeShareableFile(), encoding: .utf8)
    let clearedDevExport = try String(contentsOf: devStore.makeShareableFile(), encoding: .utf8)

    XCTAssertTrue(retainedReleaseExport.contains("environment=production"))
    XCTAssertTrue(retainedReleaseExport.contains("diagnostic_sync_last_success operation=sync.send"))
    XCTAssertFalse(clearedDevExport.contains("diagnostic_event"))
    XCTAssertFalse(clearedDevExport.contains("diagnostic_sync_"))
  }

  func testSameBundleHostsKeepExplicitDiagnosticsDirectoriesSeparate() throws {
    let cachesURL = temporaryDirectory.appendingPathComponent("Caches", isDirectory: true)
    let firstRoot = temporaryDirectory.appendingPathComponent("host-a", isDirectory: true)
    let secondRoot = temporaryDirectory.appendingPathComponent("host-b", isDirectory: true)
    let firstDirectory = AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: cachesURL,
      bundleIdentifier: "org.example.snipsnap.tests",
      isolatedDirectoryPath: firstRoot.path
    )
    let secondDirectory = AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: cachesURL,
      bundleIdentifier: "org.example.snipsnap.tests",
      isolatedDirectoryPath: secondRoot.path
    )
    let firstStore = AppDiagnosticEventStore(
      directoryURL: firstDirectory, maxBytes: 4_096, appVersion: "1", appBuild: "2"
    )
    let secondStore = AppDiagnosticEventStore(
      directoryURL: secondDirectory, maxBytes: 4_096, appVersion: "1", appBuild: "2"
    )
    firstStore.append(.syncSnapshot(scope: .records, phase: .blocked, blockedRecords: 2))
    secondStore.append(.syncSnapshot(scope: .records, phase: .active, pendingUploads: 4))

    let firstExport = try String(contentsOf: firstStore.makeShareableFile(), encoding: .utf8)
    let secondExport = try String(contentsOf: secondStore.makeShareableFile(), encoding: .utf8)

    XCTAssertEqual(firstDirectory, firstRoot)
    XCTAssertEqual(secondDirectory, secondRoot)
    XCTAssertEqual(
      AppDiagnosticEventStore.storageDirectoryURL(
        cachesURL: cachesURL,
        bundleIdentifier: "org.example.snipsnap.tests",
        environment: [
          "SNIP_SNAP_DIAGNOSTICS_DIRECTORY": firstRoot.path,
          "SNIP_SNAP_STORE_PATH": secondRoot.appendingPathComponent("items.json").path,
        ]
      ),
      firstDirectory
    )
    XCTAssertTrue(firstExport.contains("blocked_records=2"))
    XCTAssertFalse(firstExport.contains("pending_uploads=4"))
    XCTAssertTrue(secondExport.contains("pending_uploads=4"))
    XCTAssertFalse(secondExport.contains("blocked_records=2"))
    XCTAssertFalse(firstExport.contains("host-a"))
    XCTAssertFalse(secondExport.contains("host-b"))

    try firstStore.clear()
    let retainedSecondExport = try String(contentsOf: secondStore.makeShareableFile(), encoding: .utf8)

    XCTAssertTrue(retainedSecondExport.contains("diagnostic_sync_latest"))
    XCTAssertTrue(retainedSecondExport.contains("pending_uploads=4"))
  }

  func testEmptyAndRelativeDiagnosticsDirectoryOverridesUseTheBundleCache() {
    let cachesURL = temporaryDirectory.appendingPathComponent("Caches", isDirectory: true)
    let expected = cachesURL.appendingPathComponent("org.example.snipsnap", isDirectory: true)
      .appendingPathComponent("SnipSnapDiagnostics", isDirectory: true)

    for override in [nil, "", "diagnostics", "relative/diagnostics"] as [String?] {
      XCTAssertEqual(
        AppDiagnosticEventStore.storageDirectoryURL(
          cachesURL: cachesURL,
          bundleIdentifier: "org.example.snipsnap",
          isolatedDirectoryPath: override
        ),
        expected
      )
    }
  }

  func testUnownedSharedDiagnosticsAreNeitherImportedNorCleared() throws {
    let cachesURL = temporaryDirectory.appendingPathComponent("Caches", isDirectory: true)
    let sharedDirectory = cachesURL.appendingPathComponent("SnipSnapDiagnostics", isDirectory: true)
    try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
    let sharedFiles = [
      "diagnostic-events.txt": "2026-09-22T05:00:28Z diagnostic_event "
        + "operation=sync.fetch outcome=succeeded visibility=background\n",
      "diagnostic-sync-health.txt": "2026-09-22T05:00:28Z diagnostic_event "
        + "operation=sync.snapshot outcome=succeeded visibility=background "
        + "scope=transport environment=production pending_uploads=99\n",
      "attachment-events.txt": "2026-09-22T05:00:28Z attachment_download "
        + "stage=cache_install outcome=failed error=storage.pathOutsideRoot\n",
      "Snip-Snap-Diagnostics.txt": "Snip Snap diagnostics\n",
    ]
    for (name, contents) in sharedFiles {
      try contents.write(to: sharedDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let directory = AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: cachesURL,
      bundleIdentifier: "org.example.snipsnap.dev1",
      isolatedDirectoryPath: nil
    )
    let store = AppDiagnosticEventStore(
      directoryURL: directory, maxBytes: 4_096, appVersion: "1", appBuild: "2"
    )

    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertFalse(export.contains("diagnostic_event"))
    XCTAssertFalse(export.contains("diagnostic_sync_"))
    XCTAssertFalse(export.contains("attachment_download"))

    try store.clear()
    for (name, contents) in sharedFiles {
      XCTAssertEqual(
        try String(contentsOf: sharedDirectory.appendingPathComponent(name), encoding: .utf8),
        contents
      )
    }
  }

  func testSyncSnapshotEncodesOnlyTypedObservedHealth() {
    let event = AppDiagnosticEvent.syncSnapshot(
      scope: .transport,
      environment: .development,
      phase: .remoteChecked,
      reason: .pendingWork,
      pendingUploads: 3,
      pendingDownloads: 2,
      pendingEvents: 1,
      blockedRecords: 4
    )

    XCTAssertEqual(
      event.line,
      "diagnostic_event operation=sync.snapshot outcome=succeeded visibility=background "
        + "scope=transport environment=development phase=remote_checked reason=pending_work "
        + "pending_uploads=3 pending_downloads=2 pending_events=1 blocked_records=4"
    )
  }

  func testLatestSyncHealthSurvivesHistoryRotationAndReopening() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 1_024,
      appVersion: "1",
      appBuild: "2"
    )
    store.append(
      .syncSnapshot(scope: .transport, environment: .production, phase: .active, pendingEvents: 2),
      at: Date(timeIntervalSince1970: 0)
    )
    store.append(
      .syncSnapshot(scope: .records, phase: .blocked, reason: .recordBlocked, blockedRecords: 3),
      at: Date(timeIntervalSince1970: 1)
    )
    store.append(.succeeded(operation: "sync.fetch"), at: Date(timeIntervalSince1970: 2))
    store.append(.succeeded(operation: "sync.send"), at: Date(timeIntervalSince1970: 3))
    for index in 10..<30 {
      store.append(.started(operation: "clipboard.persist"), at: Date(timeIntervalSince1970: TimeInterval(index)))
    }
    let reopened = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 1_024,
      appVersion: "1",
      appBuild: "3"
    )

    let export = try String(contentsOf: reopened.makeShareableFile(), encoding: .utf8)

    XCTAssertTrue(export.contains(
      "1970-01-01T00:00:00Z diagnostic_sync_latest operation=sync.snapshot outcome=succeeded "
        + "visibility=background scope=transport environment=production phase=active pending_events=2"
    ))
    XCTAssertTrue(export.contains(
      "1970-01-01T00:00:01Z diagnostic_sync_latest operation=sync.snapshot outcome=succeeded "
        + "visibility=background scope=records phase=blocked reason=record_blocked blocked_records=3"
    ))
    XCTAssertTrue(export.contains(
      "1970-01-01T00:00:02Z diagnostic_sync_last_success operation=sync.fetch outcome=succeeded"
    ))
    XCTAssertTrue(export.contains(
      "1970-01-01T00:00:03Z diagnostic_sync_last_success operation=sync.send outcome=succeeded"
    ))
    XCTAssertTrue(export.contains("1970-01-01T00:00:29Z diagnostic_event operation=clipboard.persist"))
    XCTAssertLessThanOrEqual(export.utf8.count, 1_024)
  }

  func testLatestSyncObservationReplacesOldValuesAndKeepsUnknownValuesAbsent() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "1",
      appBuild: "2"
    )
    store.append(
      .syncSnapshot(
        scope: .transport,
        environment: .development,
        phase: .active,
        pendingUploads: 7,
        pendingDownloads: 6,
        pendingEvents: 5,
        blockedRecords: 4
      ),
      at: Date(timeIntervalSince1970: 0)
    )
    store.append(
      .syncSnapshot(scope: .records, environment: .unknown, phase: .seeding, pendingUploads: 2),
      at: Date(timeIntervalSince1970: 1)
    )
    store.append(
      .syncSnapshot(
        scope: .transport,
        phase: .remoteCheckedMissingZone,
        pendingUploads: -1,
        pendingDownloads: -2,
        pendingEvents: -3,
        blockedRecords: -4
      ),
      at: Date(timeIntervalSince1970: 2)
    )

    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    let observations = export.split(separator: "\n")
      .filter { $0.contains("diagnostic_sync_latest") }.map(String.init)

    XCTAssertEqual(observations, [
      "1970-01-01T00:00:02Z diagnostic_sync_latest operation=sync.snapshot outcome=succeeded "
        + "visibility=background scope=transport phase=remote_checked_missing_zone",
      "1970-01-01T00:00:01Z diagnostic_sync_latest operation=sync.snapshot outcome=succeeded "
        + "visibility=background scope=records environment=unknown phase=seeding pending_uploads=2",
    ])
  }

  func testLastSuccessfulTransfersAdvanceOnlyAfterSuccess() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "1",
      appBuild: "2"
    )
    store.append(.succeeded(operation: "sync.fetch"), at: Date(timeIntervalSince1970: 0))
    store.append(.succeeded(operation: "sync.send"), at: Date(timeIntervalSince1970: 1))
    store.append(.succeeded(operation: "sync.fetch"), at: Date(timeIntervalSince1970: 2))
    store.append(
      .failure(operation: "sync.fetch", errorCode: "cloudkit.3", visibility: .background),
      at: Date(timeIntervalSince1970: 3)
    )
    store.append(
      .started(operation: "sync.send", reason: .pendingWork),
      at: Date(timeIntervalSince1970: 4)
    )

    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    let successes = export.split(separator: "\n")
      .filter { $0.contains("diagnostic_sync_last_success") }.map(String.init)

    XCTAssertEqual(successes, [
      "1970-01-01T00:00:02Z diagnostic_sync_last_success operation=sync.fetch "
        + "outcome=succeeded visibility=background",
      "1970-01-01T00:00:01Z diagnostic_sync_last_success operation=sync.send "
        + "outcome=succeeded visibility=background",
    ])
    XCTAssertTrue(export.contains(
      "operation=sync.send outcome=started visibility=background reason=pending_work"
    ))
  }

  func testExportRejectsUnknownSyncFieldsInHistoryAndRetainedHealth() throws {
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    let validHistory = "2026-09-22T05:00:28Z diagnostic_event operation=sync.snapshot "
      + "outcome=succeeded visibility=background scope=transport environment=production "
      + "phase=active pending_uploads=0 pending_downloads=2 pending_events=1 blocked_records=3"
    let validHealth = "2026-09-22T05:00:29Z diagnostic_event operation=sync.snapshot "
      + "outcome=succeeded visibility=background scope=records phase=blocked "
      + "reason=record_blocked blocked_records=4"
    let prefix = "2026-09-22T05:00:30Z diagnostic_event operation=sync.snapshot "
      + "outcome=succeeded visibility=background "
    let invalid = [
      "scope=privateRecord",
      "scope=transport environment=privateName",
      "scope=transport phase=privateHash",
      "scope=transport reason=privateContent",
      "scope=transport pending_uploads=privateName",
      "scope=transport pending_uploads=01",
      "scope=transport pending_downloads=-1",
      "scope=transport pending_events=1.5",
      "scope=transport blocked_records=9223372036854775808",
      "scope=transport record_id=privateRecord",
      "scope=transport name=privateName",
      "scope=transport path=/private/file.txt",
      "scope=transport hash=privateHash",
      "scope=transport scope=records",
    ].map { prefix + $0 }
    try ([validHistory] + invalid).joined(separator: "\n")
      .write(to: temporaryDirectory.appendingPathComponent("diagnostic-events.txt"), atomically: true, encoding: .utf8)
    try ([validHealth] + invalid).joined(separator: "\n")
      .write(to: temporaryDirectory.appendingPathComponent("diagnostic-sync-health.txt"), atomically: true, encoding: .utf8)
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 8_192,
      appVersion: "1",
      appBuild: "2"
    )

    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    let history = export.split(separator: "\n")
      .filter { $0.contains("diagnostic_event") }.map(String.init)

    XCTAssertEqual(history, [validHistory])
    XCTAssertTrue(export.contains(
      "diagnostic_sync_latest operation=sync.snapshot outcome=succeeded visibility=background "
        + "scope=records phase=blocked reason=record_blocked blocked_records=4"
    ))
    XCTAssertFalse(export.contains("private"))
    XCTAssertFalse(export.contains("pending_uploads=01"))
    XCTAssertFalse(export.contains("pending_downloads=-1"))
    XCTAssertFalse(export.contains("pending_events=1.5"))
    XCTAssertFalse(export.contains("blocked_records=9223372036854775808"))
  }

  func testUnobservedSyncHealthStaysAbsentOnExport() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "1",
      appBuild: "2"
    )

    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertFalse(export.contains("diagnostic_sync_"))
    XCTAssertFalse(export.contains("pending_uploads="))
    XCTAssertFalse(export.contains("pending_downloads="))
  }

  func testObservedSyncHealthSurvivesAFailedHistoryWrite() throws {
    let eventsURL = temporaryDirectory.appendingPathComponent("diagnostic-events.txt", isDirectory: true)
    try FileManager.default.createDirectory(at: eventsURL, withIntermediateDirectories: true)
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "1",
      appBuild: "2"
    )

    store.append(
      .syncSnapshot(scope: .records, phase: .active, reason: .pendingWork, pendingDownloads: 8),
      at: Date(timeIntervalSince1970: 0)
    )
    XCTAssertEqual(try eventsURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
    try FileManager.default.removeItem(at: eventsURL)
    let reopened = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "1",
      appBuild: "2"
    )
    let export = try String(contentsOf: reopened.makeShareableFile(), encoding: .utf8)

    XCTAssertTrue(export.contains(
      "1970-01-01T00:00:00Z diagnostic_sync_latest operation=sync.snapshot outcome=succeeded "
        + "visibility=background scope=records phase=active reason=pending_work pending_downloads=8"
    ))
    XCTAssertFalse(export.contains("diagnostic_event"))
  }

  func testExportRefreshesBuildMetadataWithoutANewEvent() throws {
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    let eventsURL = temporaryDirectory.appendingPathComponent("diagnostic-events.txt")
    try """
      Snip Snap diagnostics
      format=2 app_version=0.5.1 app_build=91
      privacy=structured-operational-events-only
      2026-09-22T05:00:28Z diagnostic_event operation=attachment.prepare outcome=failed visibility=user error=storage.pathOutsideRoot
      """.write(to: eventsURL, atomically: true, encoding: .utf8)
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "0.5.1",
      appBuild: "92"
    )

    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertTrue(export.contains("format=3 app_version=0.5.1 app_build=92"))
    XCTAssertFalse(export.contains("app_build=91"))
    XCTAssertTrue(export.contains("operation=attachment.prepare outcome=failed"))
  }

  func testFailureEventUsesStableCodeWithoutDescriptionOrPath() {
    struct PrivateFailure: LocalizedError {
      let errorDescription: String? = "private file /private/secret.txt"
    }

    let event = AppDiagnosticEvent.failure(
      operation: "attachment.prepare",
      error: PrivateFailure(),
      visibility: .user
    )

    XCTAssertEqual(event.errorCode, "other.UnknownError")
    XCTAssertFalse(event.line.contains("private file"))
    XCTAssertFalse(event.line.contains("/private/secret.txt"))
  }

  func testClipboardPersistenceOperationKeepsItsCode() {
    let event = AppDiagnosticEvent.failure(
      operation: "clipboard.persist",
      errorCode: "cocoa.260",
      visibility: .user
    )

    XCTAssertEqual(event.operation, "clipboard.persist")
    XCTAssertTrue(event.line.contains("operation=clipboard.persist"))
  }

  func testStoreKeepsLegacyAttachmentEventsWhileWritingStructuredEvents() throws {
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    let legacyURL = temporaryDirectory.appendingPathComponent("attachment-events.txt")
    try """
      Snip Snap diagnostics
      format=1 app_version=0.5.1 app_build=91
      privacy=attachment-stage-events-only
      2026-09-22T05:00:28Z attachment_download stage=cache_install outcome=failed error=storage.pathOutsideRoot
      """.write(to: legacyURL, atomically: true, encoding: .utf8)
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "0.5.1",
      appBuild: "92"
    )

    store.append(.failure(
      operation: "attachment.prepare",
      error: CocoaError(.fileReadNoSuchFile),
      visibility: .user
    ), at: Date(timeIntervalSince1970: 0))
    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertTrue(export.contains("attachment_download stage=cache_install outcome=failed"))
    XCTAssertTrue(export.contains("diagnostic_event operation=attachment.prepare"))
    XCTAssertEqual(export.components(separatedBy: "Snip Snap diagnostics").count - 1, 1)
  }

  func testEvictedLegacyEventsDoNotReturnOnLaterAppends() throws {
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    let legacyURL = temporaryDirectory.appendingPathComponent("attachment-events.txt")
    try "2026-09-22T05:00:28Z attachment_download stage=cache_install outcome=failed error=storage.pathOutsideRoot\n"
      .write(to: legacyURL, atomically: true, encoding: .utf8)
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 330,
      appVersion: "1",
      appBuild: "2"
    )
    let event = AppDiagnosticEvent.failure(
      operation: "attachment.prepare",
      errorCode: "storage.pathOutsideRoot",
      visibility: .user
    )

    for index in 0..<5 {
      store.append(event, at: Date(timeIntervalSince1970: TimeInterval(index)))
    }
    let afterEviction = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    XCTAssertFalse(afterEviction.contains("attachment_download"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))

    store.append(event, at: Date(timeIntervalSince1970: 10))
    let laterExport = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    XCTAssertFalse(laterExport.contains("attachment_download"))
  }

  func testExportRejectsMalformedStoredLinesThatCouldRevealPrivateValues() throws {
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    let legacyURL = temporaryDirectory.appendingPathComponent("attachment-events.txt")
    try """
      2026-09-22T05:00:28Z attachment_download stage=cache_install outcome=failed error=storage.pathOutsideRoot
      2026-09-22T05:00:29Z attachment_download stage=cache_install outcome=failed path=/private/private.txt
      2026-09-22T05:00:30Z attachment_download stage=cache_install outcome=failed record_id=privateRecord
      2026-09-22T05:00:31Z attachment_download stage=cache_install outcome=failed hash=privateHash
      2026-09-22T05:00:32Z attachment_download stage=cache_install outcome=failed error=PrivateFilename
      2026-09-22T05:00:33Z attachment_download stage=cache_install outcome=failed error=storage.PrivateFilename
      """.write(to: legacyURL, atomically: true, encoding: .utf8)
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "1",
      appBuild: "2"
    )

    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertTrue(export.contains("error=storage.pathOutsideRoot"))
    XCTAssertFalse(export.contains("private"))
    XCTAssertFalse(export.contains("record_id="))
    XCTAssertFalse(export.contains("hash="))
    XCTAssertTrue(export.contains("error=other.UnknownError"))
    XCTAssertFalse(export.contains("PrivateFilename"))
  }

  func testLargeRetryIntervalSurvivesStoredLineValidation() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "1",
      appBuild: "2"
    )
    store.append(.failure(
      operation: "cloudkit.request",
      errorCode: "cloudkit.23",
      visibility: .background,
      retryAfterSeconds: 1e20
    ), at: Date(timeIntervalSince1970: 0))

    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertTrue(export.contains("operation=cloudkit.request outcome=failed"))
    XCTAssertTrue(export.contains("retry_after=1e+20"))
  }

  func testStoreDropsOldestWholeEventsAtSizeLimit() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 235,
      appVersion: "1",
      appBuild: "2"
    )
    store.append(.started(operation: "attachment.remote_fetch"), at: Date(timeIntervalSince1970: 0))
    store.append(.failure(
      operation: "attachment.prepare",
      errorCode: "storage.pathOutsideRoot",
      visibility: .user
    ), at: Date(timeIntervalSince1970: 1))

    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertFalse(export.contains("outcome=started"))
    XCTAssertTrue(export.contains("error=storage.pathOutsideRoot"))
    XCTAssertLessThanOrEqual(export.utf8.count, 235)
  }

  func testIdenticalFailuresInTheSameSecondRemainSeparateEvents() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "1",
      appBuild: "2"
    )
    let event = AppDiagnosticEvent.failure(
      operation: "attachment.prepare",
      errorCode: "storage.pathOutsideRoot",
      visibility: .user
    )
    let at = Date(timeIntervalSince1970: 0)

    store.append(event, at: at)
    store.append(event, at: at)
    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertEqual(export.components(separatedBy: event.line).count - 1, 2)
  }

  func testClearRemovesNewAndLegacyEvents() throws {
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    try "2026-09-22T05:00:28Z attachment_download stage=cache_install outcome=failed\n"
      .write(to: temporaryDirectory.appendingPathComponent("attachment-events.txt"), atomically: true, encoding: .utf8)
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "1",
      appBuild: "2"
    )
    store.append(.started(operation: "attachment.remote_fetch"))
    store.append(.syncSnapshot(scope: .transport, environment: .development, pendingEvents: 2))
    store.append(.syncSnapshot(scope: .records, phase: .blocked, blockedRecords: 1))
    store.append(.succeeded(operation: "sync.fetch"))
    store.append(.succeeded(operation: "sync.send"))
    let beforeClear = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    XCTAssertTrue(beforeClear.contains("diagnostic_sync_latest"))
    XCTAssertTrue(beforeClear.contains("diagnostic_sync_last_success"))

    try store.clear()
    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertFalse(export.contains("attachment_download"))
    XCTAssertFalse(export.contains("diagnostic_event"))
    XCTAssertFalse(export.contains("diagnostic_sync_"))
  }

  func testRepeatedLegacyHeadersAreReplacedByOneCurrentHeader() throws {
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    try """
      Snip Snap diagnostics
      format=1 app_version=0.5.1 app_build=84
      privacy=attachment-stage-events-only
      Snip Snap diagnostics
      format=1 app_version=0.5.1 app_build=84
      privacy=attachment-stage-events-only
      2026-09-21T19:43:28Z attachment_download stage=cache_install outcome=failed error=storage.pathOutsideRoot
      """.write(to: temporaryDirectory.appendingPathComponent("attachment-events.txt"), atomically: true, encoding: .utf8)
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory,
      maxBytes: 4_096,
      appVersion: "0.5.1",
      appBuild: "92"
    )

    store.append(.started(operation: "attachment.remote_fetch"))
    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertEqual(export.components(separatedBy: "Snip Snap diagnostics").count - 1, 1)
    XCTAssertTrue(export.contains("app_build=92"))
    XCTAssertFalse(export.contains("app_build=84"))
    XCTAssertTrue(export.contains("stage=cache_install outcome=failed"))
    XCTAssertTrue(export.contains("operation=attachment.remote_fetch outcome=started"))
  }

  @MainActor
  func testRepeatedSyncIssueRecordsOneUserVisibleFailureWithoutSetupMessage() {
    let probe = AppDiagnosticRecorderProbe()
    let model = SyncedContentSettingsModel(
      mode: .iCloudSync,
      diagnostics: probe.recorder
    )

    model.recordSyncFailure(.setupBlocked("private attachment name"))
    model.recordSyncFailure(.setupBlocked("private attachment name"))

    XCTAssertEqual(model.state, .failed(.setupBlocked("private attachment name")))
    XCTAssertEqual(probe.events.count, 1)
    XCTAssertEqual(probe.events.first?.errorCode, "sync.setupBlocked")
    XCTAssertFalse(probe.events.first?.line.contains("private attachment name") ?? true)
  }

  @MainActor
  func testEnableSetupIssueRecordsOnceWhenTheIssueIsDisplayed() async {
    let probe = AppDiagnosticRecorderProbe()
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      enableAction: { .settingUp(.waitingForConnection) },
      diagnostics: probe.recorder
    )

    await model.enableICloudSync()
    model.recordEnableSettingUp(.waitingForConnection)

    XCTAssertEqual(model.state, .enabling(.waitingForConnection))
    XCTAssertEqual(probe.events.count, 1)
    XCTAssertEqual(probe.events.first?.operation, "sync.setup")
    XCTAssertEqual(probe.events.first?.errorCode, "sync.waitingForConnection")
  }
}

private final class AppDiagnosticRecorderProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedEvents: [AppDiagnosticEvent] = []

  var recorder: AppDiagnosticRecorder {
    AppDiagnosticRecorder { [self] event in
      lock.withLock { storedEvents.append(event) }
    }
  }

  var events: [AppDiagnosticEvent] {
    lock.withLock { storedEvents }
  }
}
