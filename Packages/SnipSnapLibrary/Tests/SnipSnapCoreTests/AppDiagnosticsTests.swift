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

    XCTAssertTrue(export.contains("format=2 app_version=0.5.1 app_build=92"))
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
    _ = try store.makeShareableFile()

    try store.clear()
    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)

    XCTAssertFalse(export.contains("attachment_download"))
    XCTAssertFalse(export.contains("diagnostic_event"))
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
