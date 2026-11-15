import Foundation
import Observation

/// Owns diagnostic settings truth and the lifetime of one admitted user action.
/// Retain this model in the presentation host across settings dismissal and reopen;
/// canceled synchronous writes settle before the next authoritative read.
@MainActor
@Observable
public final class AppDiagnosticSettingsModel {
  public struct Failure: Sendable {
    public let operation: StaticString
    public let code: String
  }
  public enum Notice: Equatable, Sendable {
    case readFailed, saveFailed, preparationFailed, deliveryFailed, clearFailed, saved, cleared
  }

  public enum DeliveryOutcome: Sendable {
    case saved, shared, cancelled
  }

  struct Operations: Sendable {
    var readRecording: @Sendable () throws -> Bool
    var setRecording: @Sendable (Bool) throws -> Void
    var prepareExport: @Sendable (AppDiagnosticExportRange) throws -> URL
    var removeExport: @Sendable (URL) -> Void
    var clear: @Sendable () throws -> Void

    static let live = Self(
      readRecording: { try AppDiagnosticsExport.readRecordingEnabled() },
      setRecording: { try AppDiagnosticsExport.setRecordingEnabled($0) },
      prepareExport: { try AppDiagnosticsExport.makeShareableFile(range: $0) },
      removeExport: { AppDiagnosticsExport.removeShareableFile($0) },
      clear: { try AppDiagnosticsExport.clear() }
    )
  }

  /// One presentation host's lifetime. Recording truth and the shown report end with it.
  private enum Session {
    case inactive
    case active(ActiveSession)
  }

  private struct ActiveSession {
    let id = UUID()
    var recordingEnabled: Bool?
    var report: Report?
  }

  private struct Report {
    let notice: Notice
    var failure: Failure?
  }

  /// Cancellation cannot settle synchronous work, so an action can outlive its session.
  private struct Action {
    let id: UUID
    let sessionID: UUID
    let task: Task<Void, Never>
  }

  private enum Outcome<Output> {
    case succeeded(Output)
    case failed(Failure)
  }

  public var range: AppDiagnosticExportRange = .last24Hours
  private var session: Session = .inactive
  private var action: Action?
  private let operations: Operations
  private let diagnostics: AppDiagnosticRecorder

  public var recordingEnabled: Bool? { activeSession?.recordingEnabled }
  public var notice: Notice? { activeSession?.report?.notice }
  public var failure: Failure? { activeSession?.report?.failure }
  public var isBusy: Bool { action != nil }
  public var canPerformActions: Bool { !isBusy && recordingEnabled != nil }

  public convenience init() { self.init(operations: .live, diagnostics: .live) }

  init(operations: Operations, diagnostics: AppDiagnosticRecorder) {
    self.operations = operations
    self.diagnostics = diagnostics
  }

  public func dismissNotice() { updateSession { $0.report = nil } }

  public func activate() {
    if case .inactive = session { session = .active(ActiveSession()) }
    refreshRecording()
  }

  public func deactivate() {
    session = .inactive
    action?.task.cancel()
  }

  public func refreshRecording() { readRecording(preservingNotice: false) }

  private var activeSession: ActiveSession? {
    guard case .active(let current) = session else { return nil }
    return current
  }

  private func updateSession(_ change: (inout ActiveSession) -> Void) {
    guard case .active(var current) = session else { return }
    change(&current)
    session = .active(current)
  }

  private func readRecording(preservingNotice: Bool) {
    guard activeSession != nil, !isBusy else { return }
    if !preservingNotice { updateSession { $0.report = nil } }
    perform(operation: "diagnostics.recording", work: operations.readRecording) { outcome in
      switch outcome {
      case .succeeded(let enabled): self.updateSession { $0.recordingEnabled = enabled }
      case .failed(let failure):
        self.updateSession {
          $0.recordingEnabled = nil
          $0.report = Report(notice: .readFailed, failure: failure)
        }
      }
      return false
    }
  }

  public func setRecordingEnabled(_ enabled: Bool) {
    guard canPerformActions else { return }
    let operations = operations
    updateSession { $0.report = nil }
    perform(operation: "diagnostics.recording", work: {
      try operations.setRecording(enabled)
    }) { outcome in
      switch outcome {
      case .succeeded: self.updateSession { $0.recordingEnabled = enabled }
      case .failed(let failure):
        // A write can commit before returning an error. Only a fresh read confirms truth.
        self.updateSession {
          $0.recordingEnabled = nil
          $0.report = Report(notice: .saveFailed, failure: failure)
        }
        return true
      }
      return false
    }
  }

  public func clear() {
    guard canPerformActions else { return }
    updateSession { $0.report = nil }
    perform(operation: "diagnostics.clear", work: operations.clear) { outcome in
      switch outcome {
      case .succeeded: self.updateSession { $0.report = Report(notice: .cleared) }
      case .failed(let failure):
        self.updateSession { $0.report = Report(notice: .clearFailed, failure: failure) }
      }
      return false
    }
  }

  /// Delivery must settle only after native completion or teardown releases the file.
  /// Cancellation during delivery never removes a file still held by a native controller.
  public func share(deliver: @escaping @MainActor (URL) async throws -> DeliveryOutcome) {
    guard canPerformActions, let admittedSession = activeSession?.id else { return }
    let selectedRange = range
    let operations = operations
    let actionID = UUID()
    updateSession { $0.report = nil }
    action = Action(id: actionID, sessionID: admittedSession, task: Task {
      let url: URL
      do {
        url = try await runWork(operation: "diagnostics.export") {
          try operations.prepareExport(selectedRange)
        }
      } catch {
        if isCurrent(admittedSession) {
          let failure = Failure(operation: "diagnostics.export", code: diagnosticErrorCode(error))
          updateSession { $0.report = Report(notice: .preparationFailed, failure: failure) }
        }
        finish(actionID)
        return
      }
      if isCurrent(admittedSession) {
        do {
          let outcome = try await deliver(url)
          if isCurrent(admittedSession), case .saved = outcome {
            updateSession { $0.report = Report(notice: .saved) }
          }
        } catch {
          if !isDiagnosticCancellation(error) {
            diagnostics.record(.failure(operation: "diagnostics.export", error: error, visibility: .user))
            if isCurrent(admittedSession) {
              let failure = Failure(operation: "diagnostics.export", code: diagnosticErrorCode(error))
              updateSession { $0.report = Report(notice: .deliveryFailed, failure: failure) }
            }
          }
        }
      }
      // Also dispose successful preparation that arrived after cancellation. This cleanup
      // intentionally ignores cancellation and completes before admitting another action.
      await Task.detached(priority: .utility) { operations.removeExport(url) }.value
      finish(actionID)
    })
  }

  private func perform<Output: Sendable>(
    operation: StaticString,
    work: @escaping @Sendable () throws -> Output,
    completion: @escaping @MainActor (Outcome<Output>) -> Bool
  ) {
    guard let admittedSession = activeSession?.id else { return }
    let actionID = UUID()
    action = Action(id: actionID, sessionID: admittedSession, task: Task {
      let outcome: Outcome<Output>
      do { outcome = .succeeded(try await runWork(operation: operation, work: work)) }
      catch { outcome = .failed(Failure(operation: operation, code: diagnosticErrorCode(error))) }
      let reconcile = isCurrent(admittedSession) && completion(outcome)
      finish(actionID, reconcile: reconcile)
    })
  }

  private func runWork<Output: Sendable>(
    operation: StaticString, work: @escaping @Sendable () throws -> Output
  ) async throws -> Output {
    let diagnostics = diagnostics
    let worker = Task.detached(priority: .utility) {
      do {
        try Task.checkCancellation()
        return try work()
      } catch {
        if !isDiagnosticCancellation(error) {
          diagnostics.record(.failure(operation: operation, error: error, visibility: .user))
        }
        throw error
      }
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  private func isCurrent(_ admittedSession: UUID) -> Bool {
    activeSession?.id == admittedSession && !Task.isCancelled
  }

  private func finish(_ actionID: UUID, reconcile: Bool = false) {
    guard let settled = action, settled.id == actionID else { return }
    action = nil
    // Canceled synchronous work may still commit. A retained owner waits for settlement.
    if let current = activeSession, current.id != settled.sessionID || reconcile {
      readRecording(preservingNotice: reconcile)
    }
  }
}
