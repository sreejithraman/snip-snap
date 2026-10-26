import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest
@testable import SnipSnapCLI

final class SnipCLIAppReadinessTests: XCTestCase {
  func testUnavailableReadinessHasAnActionableMessageAndStableDiagnostic() {
    let error = SnipCLIAppReadinessError.unavailable
    XCTAssertEqual(error.localizedDescription,
      "Snip Snap couldn’t prepare its command connection. Quit and reopen Snip Snap, then try again.")
    let event = AppDiagnosticEvent.failure(operation: "cli.readiness", error: error, visibility: .user)
    XCTAssertEqual(event.operation, "cli.readiness")
    XCTAssertEqual(event.errorCode, "cli.unavailable")
  }

  func testSuspensionBetweenReadinessAndEnqueueLeavesNoQueuedMutation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let instance = SnipCLIAppInstance(pid: 123, launchDate: Date(timeIntervalSince1970: 10),
                                     applicationURL: URL(fileURLWithPath: "/tmp/Example.app"))
    try await store.beginAppSession(instance)
    try await store.publishActiveScopeToken("local")
    let published = try await store.appReadiness()
    let ready = try XCTUnwrap(published)
    try await store.suspendActiveScope()
    let request = SnipCLIRequest(action: .createList(name: "Must not be queued"))
    do {
      _ = try await SnipCLIService.execute(request, store: store, readiness: ready)
      XCTFail("Suspension during admission must reject the command.")
    } catch SnipCLIRequestError.scopeChanged {}
    try await store.publishActiveScopeToken("local")
    let state = try await store.state(for: request.requestID)
    XCTAssertEqual(state, .missing)
    await store.processPending { request in
      XCTFail("Rejected admission must not execute later.")
      return SnipCLIReceipt(request: request, status: .success)
    }
  }

  func testTerminatedOwnerCannotPublishOrRemoveReplacementReadiness() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = SnipCLIRequestStore(rootURL: root)
    let old = SnipCLIAppInstance(pid: 123, launchDate: Date(timeIntervalSince1970: 10),
                                applicationURL: URL(fileURLWithPath: "/tmp/Example.app"))
    try await first.beginAppSession(old)
    try await first.publishActiveScopeToken("local")
    try await first.endAppSession()
    let offlineScope = try await first.activeScopeToken()
    XCTAssertEqual(offlineScope, "local", "Termination preserves receipt lookup in the last library.")
    let second = SnipCLIRequestStore(rootURL: root)
    let current = SnipCLIAppInstance(pid: 456, launchDate: Date(timeIntervalSince1970: 20),
                                    applicationURL: URL(fileURLWithPath: "/tmp/Example.app"))
    try await second.beginAppSession(current)
    try await second.publishActiveScopeToken("local")
    do {
      try await first.publishActiveScopeToken("old")
      XCTFail("An old completion must not publish availability.")
    } catch SnipCLIAppReadinessError.unavailable {}
    try await first.suspendActiveScope()
    try await first.endAppSession()
    let ready = try await second.appReadiness()
    XCTAssertEqual(ready?.instance, current)
    XCTAssertEqual(ready?.scopeToken, "local")
  }

  func testBundledCLIRequiresTheExactAppEvenWhenAutomaticLaunchIsDisabled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Expected.app")
    let executable = app.appendingPathComponent("Contents/MacOS/snipsnap")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                          withIntermediateDirectories: true)
    let info: [String: String] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "test.app",
      "SnipSnapDevelopmentStorePath": root.appendingPathComponent("items.json").path]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let store = SnipCLIRequestStore(rootURL: root)
    let wrong = SnipCLIAppInstance(pid: 123, launchDate: Date(timeIntervalSince1970: 10),
                                  applicationURL: root.appendingPathComponent("Other.app"))
    try await store.beginAppSession(wrong)
    try await store.publishActiveScopeToken("local")
    let runtime = SnipCLIApplicationRuntime(applications: { _ in [SnipCLIAppProcess(
      pid: wrong.pid, launchDate: wrong.launchDate, applicationURL: URL(fileURLWithPath: wrong.applicationPath)
    )] }, launch: { _, _ in XCTFail("Automatic launch was disabled.") }, wait: {})
    let location = try SnipCLIApplicationLocation(executableURL: executable,
      environment: ["SNIP_SNAP_CLI_NO_LAUNCH": "1"])
    do {
      _ = try await location.launchIfNeeded(store: store, runtime: runtime, timeout: .zero)
      XCTFail("A matching bundle ID at another path must not grant readiness.")
    } catch SnipSnapCLIError.appUnavailable {}
    let correctApp = SnipCLIRequestStore(rootURL: root)
    let correct = SnipCLIAppInstance(pid: 456, launchDate: wrong.launchDate, applicationURL: app)
    try await correctApp.beginAppSession(correct)
    try await correctApp.publishActiveScopeToken("local")
    let currentRuntime = SnipCLIApplicationRuntime(applications: { _ in [SnipCLIAppProcess(
      pid: correct.pid, launchDate: correct.launchDate, applicationURL: app
    )] }, launch: { _, _ in XCTFail("A ready app needs no launch.") }, wait: {})
    let ready = try await location.launchIfNeeded(store: store, runtime: currentRuntime)
    XCTAssertEqual(ready?.instance, correct)
  }

  func testColdLaunchWaitsForTheCurrentInstanceInsteadOfAcceptingTheOldMarker() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let old = SnipCLIAppInstance(pid: 123, launchDate: Date(timeIntervalSince1970: 10),
                                 applicationURL: URL(fileURLWithPath: "/tmp/Example.app"))
    try await store.beginAppSession(old)
    try await store.publishActiveScopeToken("local")
    let current = SnipCLIAppInstance(pid: 123, launchDate: Date(timeIntervalSince1970: 20),
                                     applicationURL: URL(fileURLWithPath: "/tmp/Example.app"))
    let newApp = SnipCLIRequestStore(rootURL: root)
    let runtime = SnipCLIApplicationRuntime(
      applications: { _ in [SnipCLIAppProcess(pid: current.pid, launchDate: current.launchDate,
                                              applicationURL: URL(fileURLWithPath: current.applicationPath))] },
      launch: { _, _ in },
      wait: {
        try await newApp.beginAppSession(current)
        try await newApp.publishActiveScopeToken("local")
      }
    )
    let location = try SnipCLIApplicationLocation(executableURL: root.appendingPathComponent("tool"),
                                                  environment: [:])
    let ready = try await location.launchIfNeeded(store: store, runtime: runtime)
    XCTAssertEqual(ready?.instance, current)
  }

  func testAdmissionRejectsPreviousLaunchEvenWhenScopeAndPIDAreUnchanged() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstApp = SnipCLIRequestStore(rootURL: root)
    let first = SnipCLIAppInstance(pid: 123, launchDate: Date(timeIntervalSince1970: 10),
                                   applicationURL: URL(fileURLWithPath: "/tmp/Example.app"))
    try await firstApp.beginAppSession(first)
    try await firstApp.publishActiveScopeToken("local")
    let published = try await firstApp.appReadiness()
    let readiness = try XCTUnwrap(published)
    let secondApp = SnipCLIRequestStore(rootURL: root)
    let second = SnipCLIAppInstance(pid: 123, launchDate: Date(timeIntervalSince1970: 20),
                                    applicationURL: URL(fileURLWithPath: "/tmp/Example.app"))
    try await secondApp.beginAppSession(second)
    try await secondApp.publishActiveScopeToken("local")
    let request = SnipCLIRequest(action: .listLists, scopeToken: "local")
    do {
      _ = try await firstApp.enqueue(request, readiness: readiness)
      XCTFail("A previous launch must not admit a request into the new app.")
    } catch SnipCLIAppReadinessError.unavailable {}
    let state = try await secondApp.state(for: request.requestID)
    XCTAssertEqual(state, .missing)
    _ = try await secondApp.enqueue(request, readiness: try await secondApp.appReadiness())
    let admitted = try await secondApp.state(for: request.requestID)
    XCTAssertEqual(admitted, .pending)
  }
}
