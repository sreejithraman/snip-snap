import Foundation
import XCTest

@testable import SnipSnapCore

@MainActor
final class AppDiagnosticSettingsModelTests: XCTestCase {
  func testFailedRefreshForgetsConfirmedTruthAndRetryRecoversChangedPreference() async throws {
    let backend = SettingsBackend()
    let model = AppDiagnosticSettingsModel(operations: backend.operations, diagnostics: backend.recorder)
    model.activate()
    await settled(model)
    XCTAssertEqual(model.recordingEnabled, true)

    backend.readFails = true
    backend.enabled = false
    model.refreshRecording()
    await settled(model)
    XCTAssertNil(model.recordingEnabled)
    XCTAssertFalse(model.canPerformActions)
    XCTAssertEqual(model.notice, .readFailed)
    model.setRecordingEnabled(true)
    model.clear()
    model.share { _ in XCTFail("Unknown truth must reject delivery"); return .shared }
    await settled(model)
    XCTAssertFalse(backend.enabled)
    XCTAssertFalse(backend.wasCleared)

    backend.readFails = false
    model.refreshRecording()
    await settled(model)
    XCTAssertEqual(model.recordingEnabled, false)
    XCTAssertTrue(model.canPerformActions)
    XCTAssertNil(model.notice)
  }

  func testFailedWriteReconcilesCommittedValueAndReportsOnlySanitizedMetadata() async {
    let backend = SettingsBackend()
    var operations = backend.operations
    operations.setRecording = { enabled in
      backend.enabled = enabled
      throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
        userInfo: [NSLocalizedDescriptionKey: "private recipient /private/customer/report.txt"])
    }
    let model = AppDiagnosticSettingsModel(operations: operations, diagnostics: backend.recorder)
    model.activate()
    await settled(model)
    model.setRecordingEnabled(false)
    await settled(model)
    XCTAssertEqual(model.recordingEnabled, false)
    XCTAssertTrue(model.canPerformActions)
    XCTAssertEqual(model.notice, .saveFailed)
    XCTAssertEqual(backend.events.map(\.line), [
      "diagnostic_event operation=diagnostics.recording outcome=failed visibility=user error=cocoa.513"
    ])
    model.dismissNotice()
    model.clear()
    await settled(model)
    XCTAssertTrue(backend.wasCleared)
    XCTAssertEqual(model.recordingEnabled, false, "Clear preserves recording off")
    XCTAssertEqual(model.notice, .cleared)
  }

  func testExportCapturesRangeExcludesOtherActionsAndKeepsRealFileUntilSaved() async throws {
    let backend = SettingsBackend()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppDiagnosticEventStore(directoryURL: root, appVersion: "1", appBuild: "2")
    let gate = BlockingSettingsWork()
    defer { gate.release() }
    var operations = backend.operations
    operations.prepareExport = { range in
      let url = try store.makeShareableFile(range: range)
      gate.block()
      return url
    }
    operations.removeExport = { store.removeShareableFile($0) }
    let model = AppDiagnosticSettingsModel(operations: operations, diagnostics: backend.recorder)
    model.activate()
    await settled(model)
    model.range = .last7Days
    let delivery = SettingsDelivery()
    model.share(deliver: delivery.deliver)
    XCTAssertTrue(model.isBusy)
    guard model.isBusy else { return }
    await until { gate.hasEntered }
    model.range = .last24Hours
    model.clear()
    model.setRecordingEnabled(false)
    model.share { _ in XCTFail("Only one export is admitted"); return .shared }
    model.refreshRecording()
    gate.release()
    await until { delivery.url != nil }
    let url = try XCTUnwrap(delivery.url)
    XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("selected_range=last7Days"))
    XCTAssertTrue(model.isBusy)
    XCTAssertFalse(model.canPerformActions)
    XCTAssertFalse(backend.wasCleared)
    XCTAssertTrue(backend.enabled)
    delivery.finish(.success(.saved))
    await settled(model)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(model.notice, .saved)
    XCTAssertTrue(model.canPerformActions)
  }

  func testDismissAndReopenWaitsForCanceledCommittedWriteThenReadsFreshTruth() async {
    for failsAfterCommit in [false, true] {
      let backend = SettingsBackend()
      let gate = BlockingSettingsWork()
      defer { gate.release() }
      var operations = backend.operations
      operations.setRecording = { enabled in
        gate.block()
        backend.enabled = enabled
        if failsAfterCommit { throw CocoaError(.fileWriteUnknown) }
      }
      let model = AppDiagnosticSettingsModel(operations: operations, diagnostics: backend.recorder)
      model.activate()
      await settled(model)
      model.setRecordingEnabled(false)
      await until { gate.hasEntered }
      model.deactivate()
      XCTAssertNil(model.recordingEnabled)
      model.activate()
      XCTAssertTrue(model.isBusy)
      XCTAssertFalse(model.canPerformActions)
      model.clear()
      gate.release()
      await settled(model)
      XCTAssertEqual(model.recordingEnabled, false)
      XCTAssertTrue(model.canPerformActions)
      XCTAssertNil(model.notice, "An old presentation must not show completion notices")
      XCTAssertFalse(backend.wasCleared)
    }
  }

  func testFailedWriteWithUnavailableReconciliationRemainsUnknownUntilRetry() async {
    let backend = SettingsBackend()
    var operations = backend.operations
    operations.setRecording = { enabled in
      backend.enabled = enabled
      backend.readFails = true
      throw CocoaError(.fileWriteUnknown)
    }
    let model = AppDiagnosticSettingsModel(operations: operations, diagnostics: backend.recorder)
    model.activate()
    await settled(model)
    model.setRecordingEnabled(false)
    await settled(model)
    XCTAssertNil(model.recordingEnabled)
    XCTAssertEqual(model.notice, .readFailed)
    model.clear()
    XCTAssertFalse(backend.wasCleared)
    backend.readFails = false
    model.refreshRecording()
    await settled(model)
    XCTAssertEqual(model.recordingEnabled, false)
    XCTAssertTrue(model.canPerformActions)
  }

  func testInactiveActionsAreRejectedAndDisabledRecordingStillAllowsExportAndClear() async {
    let backend = SettingsBackend()
    let model = AppDiagnosticSettingsModel(operations: backend.operations, diagnostics: backend.recorder)
    model.setRecordingEnabled(false)
    model.clear()
    model.share { _ in XCTFail("Inactive delivery"); return .shared }
    await settled(model)
    XCTAssertTrue(backend.enabled)
    XCTAssertFalse(backend.wasCleared)
    backend.enabled = false
    model.activate()
    await settled(model)
    model.share { _ in XCTFail("Preparation should fail"); return .shared }
    await settled(model)
    XCTAssertEqual(model.notice, .preparationFailed)
    XCTAssertEqual(backend.events.map(\.line), [
      "diagnostic_event operation=diagnostics.export outcome=failed visibility=user error=cocoa.4"
    ])
    model.clear()
    await settled(model)
    XCTAssertTrue(backend.wasCleared)
    XCTAssertEqual(model.recordingEnabled, false)
    model.deactivate()
    model.setRecordingEnabled(true)
    XCTAssertFalse(backend.enabled)
    XCTAssertNil(model.notice)
  }

  func testExportRemainsReadableThroughAllTerminalOutcomesAndHostDeactivation() async throws {
    let outcomes: [Result<AppDiagnosticSettingsModel.DeliveryOutcome, any Error>] = [
      .success(.saved), .success(.shared), .success(.cancelled),
      .failure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
        userInfo: [NSLocalizedDescriptionKey: "private recipient /private/customer/report.txt"]))
    ]
    for deactivate in [false, true] {
      for outcome in outcomes {
        let backend = SettingsBackend()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppDiagnosticEventStore(directoryURL: root, appVersion: "1", appBuild: "2")
        var operations = backend.operations
        operations.prepareExport = { try store.makeShareableFile(range: $0) }
        operations.removeExport = { store.removeShareableFile($0) }
        let model = AppDiagnosticSettingsModel(operations: operations, diagnostics: backend.recorder)
        model.activate()
        await settled(model)
        let delivery = SettingsDelivery()
        model.share(deliver: delivery.deliver)
        await until { delivery.url != nil }
        let url = try XCTUnwrap(delivery.url)
        if deactivate {
          model.deactivate()
          backend.enabled = false
          model.activate()
          XCTAssertNil(model.recordingEnabled)
        }
        await Task.yield()
        XCTAssertTrue(model.isBusy, "Cancellation cannot settle a native controller")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("selected_range=last24Hours"))
        delivery.finish(outcome)
        await settled(model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        if deactivate {
          XCTAssertEqual(model.recordingEnabled, false)
          XCTAssertNil(model.notice, "No old saved or failure notice appears on reopen")
        } else {
          switch outcome {
          case .success(.saved): XCTAssertEqual(model.notice, .saved)
          case .failure: XCTAssertEqual(model.notice, .deliveryFailed)
          default: XCTAssertNil(model.notice, "Normal sharing and cancellation stay quiet")
          }
        }
        if case .failure = outcome {
          XCTAssertEqual(backend.events.map(\.line), [
            "diagnostic_event operation=diagnostics.export outcome=failed visibility=user error=cocoa.513"
          ])
        } else {
          XCTAssertTrue(backend.events.isEmpty)
        }
        XCTAssertTrue(model.canPerformActions)
      }
    }
  }

  func testOutputArrivingAfterCanceledPreparationIsDisposedWithoutDeliveryOrNotice() async throws {
    let backend = SettingsBackend()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppDiagnosticEventStore(directoryURL: root, appVersion: "1", appBuild: "2")
    let gate = BlockingSettingsWork()
    defer { gate.release() }
    var operations = backend.operations
    operations.prepareExport = { range in
      let url = try store.makeShareableFile(range: range)
      gate.block(output: url)
      return url
    }
    operations.removeExport = { store.removeShareableFile($0) }
    let model = AppDiagnosticSettingsModel(operations: operations, diagnostics: backend.recorder)
    model.activate()
    await settled(model)
    model.share { _ in XCTFail("Canceled preparation must never present delivery"); return .shared }
    await until { gate.hasEntered }
    let url = try XCTUnwrap(gate.output)
    model.deactivate()
    model.activate()
    XCTAssertTrue(model.isBusy)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    gate.release()
    await settled(model)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(model.recordingEnabled, true)
    XCTAssertNil(model.notice)
  }

  func testExternalClearCanInvalidateDeliveryAndCleanupRemainsSafe() async throws {
    let backend = SettingsBackend()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppDiagnosticEventStore(directoryURL: root, appVersion: "1", appBuild: "2")
    var operations = backend.operations
    operations.prepareExport = { try store.makeShareableFile(range: $0) }
    operations.removeExport = { store.removeShareableFile($0) }
    let model = AppDiagnosticSettingsModel(operations: operations, diagnostics: backend.recorder)
    model.activate()
    await settled(model)
    let delivery = SettingsDelivery()
    model.share(deliver: delivery.deliver)
    await until { delivery.url != nil }
    let url = try XCTUnwrap(delivery.url)
    try store.clear()
    do {
      _ = try Data(contentsOf: url)
      XCTFail("External clear retains its contract of invalidating staged exports")
      delivery.finish(.success(.shared))
    } catch {
      delivery.finish(.failure(error))
    }
    await settled(model)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(model.notice, .deliveryFailed)
    XCTAssertEqual(backend.events.map(\.line), [
      "diagnostic_event operation=diagnostics.export outcome=failed visibility=user error=cocoa.260"
    ])
    XCTAssertTrue(model.canPerformActions)
    store.removeShareableFile(url)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  private func until(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertTrue(condition(), "Settings effect did not reach its gate")
  }

  private func settled(_ model: AppDiagnosticSettingsModel) async {
    await until { !model.isBusy }
  }
}

private final class SettingsBackend: @unchecked Sendable {
  private let lock = NSLock()
  private var storedEnabled = true
  private var storedReadFails = false
  private var storedCleared = false
  var enabled: Bool {
    get { lock.withLock { storedEnabled } }
    set { lock.withLock { storedEnabled = newValue } }
  }
  var readFails: Bool {
    get { lock.withLock { storedReadFails } }
    set { lock.withLock { storedReadFails = newValue } }
  }
  var wasCleared: Bool { lock.withLock { storedCleared } }
  private var storedEvents: [AppDiagnosticEvent] = []
  var events: [AppDiagnosticEvent] { lock.withLock { storedEvents } }
  var recorder: AppDiagnosticRecorder {
    AppDiagnosticRecorder { event in self.lock.withLock { self.storedEvents.append(event) } }
  }
  var operations: AppDiagnosticSettingsModel.Operations {
    .init(
      readRecording: { if self.readFails { throw CocoaError(.fileReadCorruptFile) }; return self.enabled },
      setRecording: { self.enabled = $0 },
      prepareExport: { _ in throw CocoaError(.fileNoSuchFile) },
      removeExport: { _ in },
      clear: { self.lock.withLock { self.storedCleared = true } }
    )
  }
}

private final class BlockingSettingsWork: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var entered = false
  private var storedOutput: URL?
  var output: URL? { lock.withLock { storedOutput } }
  var hasEntered: Bool { lock.withLock { entered } }
  func block(output: URL? = nil) {
    lock.withLock { storedOutput = output; entered = true }
    semaphore.wait()
  }
  func release() { semaphore.signal() }
}

@MainActor
private final class SettingsDelivery {
  var url: URL?
  private var continuation: CheckedContinuation<AppDiagnosticSettingsModel.DeliveryOutcome, any Error>?
  func deliver(_ url: URL) async throws -> AppDiagnosticSettingsModel.DeliveryOutcome {
    self.url = url
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }
  func finish(_ result: Result<AppDiagnosticSettingsModel.DeliveryOutcome, any Error>) {
    let pending = continuation
    continuation = nil
    pending?.resume(with: result)
  }
}
