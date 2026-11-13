import Foundation
import MetricKit
import Synchronization
import XCTest

@testable import SnipSnapCore

final class AppTerminationDiagnosticsTests: XCTestCase {
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

  func testWatchdogKillRecordsTypedTerminationAtPayloadTime() {
    let crashedAt = Date(timeIntervalSince1970: 1_794_576_071)
    let payload = FakePayload(
      end: crashedAt,
      crashes: [
        FakeCrash(
          exceptionType: 10, signal: 9,
          terminationReason:
            "Namespace FRONTBOARD, Code 0x8badf00d scene-update watchdog transgression: "
            + "world.sree.snipsnap exhausted real (wall clock) time allowance of 10.00 seconds",
          version: "0.6.1", build: "185")
      ])

    let recorded = receive([payload], now: crashedAt.addingTimeInterval(600))

    XCTAssertEqual(recorded.count, 1)
    XCTAssertEqual(recorded.first?.date, crashedAt)
    XCTAssertEqual(
      recorded.first?.event.line,
      "diagnostic_event operation=app.termination outcome=failed visibility=background"
        + " error=termination.watchdog exception=EXC_CRASH signal=SIGKILL"
        + " termination_namespace=FRONTBOARD termination_code=0x8badf00d"
        + " exit_version=0.6.1 exit_build=185")
  }

  func testPayloadWithoutCrashesRecordsNothing() {
    let now = Date()
    XCTAssertTrue(receive([FakePayload(end: now, crashes: nil)], now: now).isEmpty)
    XCTAssertTrue(receive([FakePayload(end: now, crashes: [])], now: now).isEmpty)
  }

  func testEachCrashInEachPayloadIsRecordedAndFutureTimesAreCapped() {
    let now = Date(timeIntervalSince1970: 1_794_576_071)
    let recorded = receive(
      [
        FakePayload(
          end: now.addingTimeInterval(-60),
          crashes: [
            FakeCrash(
              exceptionType: 10, signal: 9,
              terminationReason: "Namespace RUNNINGBOARD, Code 0xdead10cc", version: "0.6.1",
              build: "180"),
            FakeCrash(
              exceptionType: 1, signal: 11, terminationReason: nil, version: "0.6.1",
              build: "180"),
          ]),
        FakePayload(
          end: now.addingTimeInterval(3_600),
          crashes: [
            FakeCrash(
              exceptionType: 6, signal: 5, terminationReason: "Namespace SIGNAL, Code 5",
              version: "0.6.1", build: "181")
          ]),
      ], now: now)

    XCTAssertEqual(recorded.map(\.event.errorCode), [
      "termination.fileLock", "termination.crash", "termination.crash",
    ])
    XCTAssertEqual(recorded.map(\.date), [
      now.addingTimeInterval(-60), now.addingTimeInterval(-60), now,
    ])
    XCTAssertEqual(recorded[1].event.termination?.exception, "EXC_BAD_ACCESS")
    XCTAssertEqual(recorded[1].event.termination?.signal, "SIGSEGV")
    XCTAssertNil(recorded[1].event.termination?.namespace)
    XCTAssertEqual(recorded[2].event.termination?.code, "0x5")
  }

  func testTerminationReasonKeepsOnlyNamespaceAndNormalizedCode() {
    let crashReportForm = AppDiagnosticTermination(
      exceptionType: 10, signal: 9,
      terminationReason: "FRONTBOARD 2343432205 <RBSTerminateContext| domain:10 code:0x8BADF00D>",
      appVersion: "0.6.1", appBuild: "185")
    XCTAssertEqual(crashReportForm.kind, .watchdog)
    XCTAssertEqual(crashReportForm.namespace, "FRONTBOARD")
    XCTAssertEqual(crashReportForm.code, "0x8badf00d")

    let unparsed = AppDiagnosticTermination(
      exceptionType: 99, signal: 31, terminationReason: "killed /private/var/Snip secret.txt",
      appVersion: "0.6.1 (beta)", appBuild: "185/../x")
    XCTAssertEqual(unparsed.kind, .crash)
    XCTAssertEqual(unparsed.exception, "99")
    XCTAssertEqual(unparsed.signal, "31")
    XCTAssertNil(unparsed.namespace)
    XCTAssertNil(unparsed.code)
    XCTAssertNil(unparsed.version)
    XCTAssertNil(unparsed.build)
    XCTAssertFalse(AppDiagnosticEvent.termination(unparsed).line.contains("secret"))
  }

  func testRecordedTerminationExportsWithCrashTimeAndBuilds() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: temporaryDirectory, policy: .init(exportBytes: 4_096),
      appVersion: "0.6.1", appBuild: "187")
    let scope = AppDiagnosticScope(store: store)
    let crashedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 3_600)
    let subscriber = AppTerminationSubscriber { scope.record($0, at: $1) }

    subscriber.didReceive([
      FakePayload(
        end: crashedAt,
        crashes: [
          FakeCrash(
            exceptionType: 10, signal: 9,
            terminationReason: "Namespace FRONTBOARD, Code 0x8badf00d", version: "0.6.1",
            build: "185")
        ])
    ])

    let log = try scope.readLog(errorsOnly: true).text
    XCTAssertTrue(
      log.contains(
        "\(crashedAt.ISO8601Format()) diagnostic_event operation=app.termination outcome=failed"
          + " visibility=background error=termination.watchdog exception=EXC_CRASH signal=SIGKILL"
          + " termination_namespace=FRONTBOARD termination_code=0x8badf00d exit_version=0.6.1"
          + " exit_build=185 schema=1 severity=error app_version=0.6.1 app_build=187"), log)
  }

  func testStoredTerminationFieldsAreRejectedOutsideTheirOperationOrSchema() {
    let valid =
      "2026-11-13T13:21:11Z diagnostic_event operation=app.termination outcome=failed"
      + " visibility=background error=termination.watchdog exception=EXC_CRASH signal=SIGKILL"
      + " termination_namespace=FRONTBOARD termination_code=0x8badf00d exit_version=0.6.1"
      + " exit_build=185"
    XCTAssertEqual(AppDiagnosticLine.sanitize(valid), valid)
    for (field, replacement) in [
      ("operation=app.termination", "operation=sync.fetch"),
      ("exception=EXC_CRASH", "exception=EXC_private"),
      ("signal=SIGKILL", "signal=-9"),
      ("termination_namespace=FRONTBOARD", "termination_namespace=frontboard"),
      ("termination_code=0x8badf00d", "termination_code=0x8BADF00D"),
      ("termination_code=0x8badf00d", "termination_code=secret"),
      ("exit_build=185", "exit_build=185-dev"),
    ] {
      XCTAssertNil(
        AppDiagnosticLine.sanitize(valid.replacingOccurrences(of: field, with: replacement)),
        replacement)
    }
  }

  private func receive(_ payloads: [MXDiagnosticPayload], now: Date) -> [(
    event: AppDiagnosticEvent, date: Date
  )] {
    let recorded = Mutex<[(event: AppDiagnosticEvent, date: Date)]>([])
    let subscriber = AppTerminationSubscriber(now: { now }) { event, date in
      recorded.withLock { $0.append((event, date)) }
    }
    subscriber.didReceive(payloads)
    return recorded.withLock { $0 }
  }
}

// MetricKit offers no public initializers; subclasses stand in for system payloads.
private final class FakePayload: MXDiagnosticPayload {
  private let end: Date
  private let crashes: [MXCrashDiagnostic]?

  init(end: Date, crashes: [MXCrashDiagnostic]?) {
    self.end = end
    self.crashes = crashes
    super.init()
  }

  required init?(coder: NSCoder) { nil }

  override var timeStampBegin: Date { end.addingTimeInterval(-86_400) }
  override var timeStampEnd: Date { end }
  override var crashDiagnostics: [MXCrashDiagnostic]? { crashes }
}

private final class FakeCrash: MXCrashDiagnostic {
  private let type: Int?
  private let signalNumber: Int?
  private let reason: String?
  private let version: String
  private let meta: FakeMetaData

  init(exceptionType: Int?, signal: Int?, terminationReason: String?, version: String, build: String)
  {
    type = exceptionType
    signalNumber = signal
    reason = terminationReason
    self.version = version
    meta = FakeMetaData(build: build)
    super.init()
  }

  required init?(coder: NSCoder) { nil }

  override var exceptionType: NSNumber? { type.map { NSNumber(value: $0) } }
  override var signal: NSNumber? { signalNumber.map { NSNumber(value: $0) } }
  override var terminationReason: String? { reason }
  override var applicationVersion: String { version }
  override var metaData: MXMetaData { meta }
}

private final class FakeMetaData: MXMetaData {
  private let build: String

  init(build: String) {
    self.build = build
    super.init()
  }

  required init?(coder: NSCoder) { nil }

  override var applicationBuildVersion: String { build }
}
