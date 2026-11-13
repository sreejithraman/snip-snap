import Foundation
import MetricKit

/// Typed facts about an abnormal exit that the platform reported on a later launch.
/// Free-form reasons, call stacks, and memory details never leave this type.
public struct AppDiagnosticTermination: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case watchdog
    case fileLock
    case crash

    var errorCode: String { "termination.\(rawValue)" }
  }

  public let kind: Kind
  public let exception: String?
  public let signal: String?
  public let namespace: String?
  public let code: String?
  public let version: String?
  public let build: String?

  public init(
    exceptionType: Int?, signal: Int?, terminationReason: String?,
    appVersion: String?, appBuild: String?
  ) {
    exception = exceptionType.flatMap { Self.name($0, in: Self.exceptionNames) }
    self.signal = signal.flatMap { Self.name($0, in: Self.signalNames) }
    let reason = terminationReason.flatMap(Self.parseReason)
    namespace = reason?.namespace
    code = reason?.code
    version = appVersion.flatMap(Self.validVersion)
    build = appBuild.flatMap(Self.validVersion)
    // The parsed code covers decimal forms; the raw reason covers codes in other positions.
    let evidence = [code, terminationReason?.lowercased()].compactMap { $0 }.joined(separator: " ")
    kind =
      if evidence.contains("8badf00d") { .watchdog }
      else if evidence.contains("dead10cc") { .fileLock }
      else { .crash }
  }

  static let fieldKeys = [
    "exception", "signal", "termination_namespace", "termination_code", "exit_version",
    "exit_build",
  ]

  var fields: [(key: String, value: String)] {
    zip(Self.fieldKeys, [exception, signal, namespace, code, version, build])
      .compactMap { key, value in value.map { (key, $0) } }
  }

  static func isValid(key: String, value: String) -> Bool {
    switch key {
    case "exception": isName(value, in: exceptionNames)
    case "signal": isName(value, in: signalNames)
    case "termination_namespace": value.wholeMatch(of: #/[A-Z][A-Z0-9_]{1,31}/#) != nil
    case "termination_code": value.wholeMatch(of: #/0x[0-9a-f]{1,16}/#) != nil
    case "exit_version", "exit_build": validVersion(value) == value
    default: false
    }
  }

  // Mach exception types from <mach/exception_types.h>.
  private static let exceptionNames: [Int: String] = [
    1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION",
    5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL",
    9: "EXC_RPC_ALERT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD",
    13: "EXC_CORPSE_NOTIFY",
  ]

  // Darwin signal numbers from <sys/signal.h>.
  private static let signalNames: [Int: String] = [
    1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT",
    7: "SIGEMT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS",
    13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM",
  ]

  /// Unknown numbers stay visible as plain decimals instead of being dropped.
  private static func name(_ number: Int, in names: [Int: String]) -> String? {
    guard number >= 0 else { return nil }
    return names[number] ?? String(number)
  }

  private static func isName(_ value: String, in names: [Int: String]) -> Bool {
    names.values.contains(value)
      || (value.count <= 10 && Int(value).map { $0 >= 0 && String($0) == value } == true)
  }

  private static func validVersion(_ value: String) -> String? {
    let version = AppDiagnosticRecord.safeVersion(value)
    return version == "unknown" ? nil : version
  }

  /// Accepts MetricKit's "Namespace FRONTBOARD, Code 0x8badf00d" and crash-report
  /// "FRONTBOARD 2343432205" forms. Only the namespace token and the code survive.
  private static func parseReason(_ reason: String) -> (namespace: String, code: String)? {
    let pattern = #/^\s*(?:Namespace\s+)?([A-Z][A-Z0-9_]{1,31}),?\s+(?:Code\s+)?(0x[0-9A-Fa-f]{1,16}|[0-9]{1,20})\b/#
    guard let match = reason.firstMatch(of: pattern) else { return nil }
    let raw = String(match.2)
    let value =
      raw.hasPrefix("0x") ? UInt64(raw.dropFirst(2), radix: 16) : UInt64(raw, radix: 10)
    guard let value else { return nil }
    return (String(match.1), "0x" + String(value, radix: 16))
  }
}

extension AppDiagnosticTermination {
  init(_ crash: MXCrashDiagnostic) {
    self.init(
      exceptionType: crash.exceptionType?.intValue, signal: crash.signal?.intValue,
      terminationReason: crash.terminationReason, appVersion: crash.applicationVersion,
      appBuild: crash.metaData.applicationBuildVersion)
  }
}

/// Records crashes and system terminations that MetricKit reports after a later launch.
/// MetricKit, not a launch sentinel, is the source: a suspended app that the system
/// reclaims exits the same way as one that crashed, and only MetricKit can tell them apart.
public enum AppTerminationDiagnostics {
  private static let subscriber = AppTerminationSubscriber { event, date in
    AppDiagnosticScope.live.record(event, at: date)
  }

  /// Call once per app launch. MetricKit holds diagnostics until a subscriber exists.
  public static func startRecording() {
    MXMetricManager.shared.add(subscriber)
  }
}

final class AppTerminationSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
  private let record: @Sendable (AppDiagnosticEvent, Date) -> Void
  private let now: @Sendable () -> Date

  init(
    now: @escaping @Sendable () -> Date = Date.init,
    record: @escaping @Sendable (AppDiagnosticEvent, Date) -> Void
  ) {
    self.now = now
    self.record = record
  }

  /// A payload carries no per-crash time. Its end bound is the closest available
  /// time; it is capped at now so a skewed payload cannot record a future event.
  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    let now = now()
    for payload in payloads {
      let date = min(payload.timeStampEnd, now)
      for crash in payload.crashDiagnostics ?? [] {
        record(.termination(AppDiagnosticTermination(crash)), date)
      }
    }
  }
}
