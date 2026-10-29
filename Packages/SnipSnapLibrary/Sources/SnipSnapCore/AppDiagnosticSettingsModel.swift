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

  public var range: AppDiagnosticExportRange = .last24Hours
  public private(set) var recordingEnabled: Bool?
  public private(set) var notice: Notice?
  public private(set) var failure: Failure?
  private var task: Task<Void, Never>?
  private var isActive = false
  private var generation = 0
  private let operations: Operations
  private let diagnostics: AppDiagnosticRecorder

  public var isBusy: Bool { task != nil }
  public var canPerformActions: Bool { isActive && !isBusy && recordingEnabled != nil }

  public convenience init() { self.init(operations: .live, diagnostics: .live) }

  init(operations: Operations, diagnostics: AppDiagnosticRecorder) {
    self.operations = operations
    self.diagnostics = diagnostics
  }

  public func dismissNotice() { notice = nil; failure = nil }

  public func activate() {
    isActive = true
    refreshRecording()
  }

  public func deactivate() {
    isActive = false
    generation += 1
    recordingEnabled = nil
    notice = nil
    failure = nil
    task?.cancel()
  }

  public func refreshRecording() { readRecording(preservingNotice: false) }

  private func readRecording(preservingNotice: Bool) {
    guard isActive, !isBusy else { return }
    if !preservingNotice { notice = nil; failure = nil }
    perform(operation: "diagnostics.recording", work: operations.readRecording) { result in
      switch result {
      case .success(let enabled): self.recordingEnabled = enabled
      case .failure:
        self.recordingEnabled = nil
        self.notice = .readFailed
      }
      return false
    }
  }

  public func setRecordingEnabled(_ enabled: Bool) {
    guard canPerformActions else { return }
    let operations = operations
    notice = nil
    failure = nil
    perform(operation: "diagnostics.recording", work: {
      try operations.setRecording(enabled)
    }) { result in
      switch result {
      case .success: self.recordingEnabled = enabled
      case .failure:
        // A write can commit before returning an error. Only a fresh read confirms truth.
        self.recordingEnabled = nil
        self.notice = .saveFailed
        return true
      }
      return false
    }
  }

  public func clear() {
    guard canPerformActions else { return }
    notice = nil
    failure = nil
    perform(operation: "diagnostics.clear", work: operations.clear) { result in
      switch result {
      case .success: self.notice = .cleared
      case .failure: self.notice = .clearFailed
      }
      return false
    }
  }

  /// Delivery must settle only after native completion or teardown releases the file.
  /// Cancellation during delivery never removes a file still held by a native controller.
  public func share(deliver: @escaping @MainActor (URL) async throws -> DeliveryOutcome) {
    guard canPerformActions else { return }
    let selectedRange = range
    let admittedGeneration = generation
    let operations = operations
    notice = nil
    failure = nil
    task = Task {
      let url: URL
      do {
        url = try await runWork(operation: "diagnostics.export") {
          try operations.prepareExport(selectedRange)
        }
      } catch {
        if isCurrent(admittedGeneration) {
          failure = Failure(operation: "diagnostics.export", code: diagnosticErrorCode(error))
          notice = .preparationFailed
        }
        finish(admittedGeneration)
        return
      }
      if isCurrent(admittedGeneration) {
        do {
          let outcome = try await deliver(url)
          if isCurrent(admittedGeneration), case .saved = outcome { notice = .saved }
        } catch {
          if !isDiagnosticCancellation(error) {
            diagnostics.record(.failure(operation: "diagnostics.export", error: error, visibility: .user))
            if isCurrent(admittedGeneration) {
              failure = Failure(operation: "diagnostics.export", code: diagnosticErrorCode(error))
              notice = .deliveryFailed
            }
          }
        }
      }
      // Also dispose successful preparation that arrived after cancellation. This cleanup
      // intentionally ignores cancellation and completes before admitting another action.
      await Task.detached(priority: .utility) { operations.removeExport(url) }.value
      finish(admittedGeneration)
    }
  }

  private func perform<Output: Sendable>(
    operation: StaticString,
    work: @escaping @Sendable () throws -> Output,
    completion: @escaping @MainActor (Result<Output, any Error>) -> Bool
  ) {
    let admittedGeneration = generation
    task = Task {
      let result: Result<Output, any Error>
      do { result = .success(try await runWork(operation: operation, work: work)) }
      catch { result = .failure(error) }
      var reconcile = false
      if isCurrent(admittedGeneration) {
        if case .failure(let error) = result {
          failure = Failure(operation: operation, code: diagnosticErrorCode(error))
        }
        reconcile = completion(result)
      }
      finish(admittedGeneration, reconcile: reconcile)
    }
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

  private func isCurrent(_ admittedGeneration: Int) -> Bool {
    isActive && generation == admittedGeneration && !Task.isCancelled
  }

  private func finish(_ admittedGeneration: Int, reconcile: Bool = false) {
    task = nil
    // Canceled synchronous work may still commit. A retained owner waits for settlement.
    if isActive, generation != admittedGeneration || reconcile {
      readRecording(preservingNotice: reconcile)
    }
  }
}
