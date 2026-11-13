import Foundation
import SnipSnapCore
import Synchronization
import XCTest

@testable import SnipSnapPersistence

final class SnipLibraryLocationTests: XCTestCase {
  private var root: URL!
  private var appGroup: SnipLibraryLocation!
  private var appContainer: SnipLibraryLocation!
  private final class EventLog: Sendable {
    let lines = Mutex<[String]>([])
  }
  private let log = EventLog()
  private var events: [String] { log.lines.withLock { $0 } }
  private var diagnostics: AppDiagnosticRecorder {
    AppDiagnosticRecorder { [log] event in log.lines.withLock { $0.append(event.line) } }
  }

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    appGroup = .appGroup(root.appendingPathComponent("Group", isDirectory: true))
    appContainer = .appContainer(
      applicationSupportURL: root.appendingPathComponent("Application Support", isDirectory: true))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testAdoptingMovesStoreAndSyncModeDataOutOfAppGroup() async throws {
    try await createList("Work", at: appGroup)
    try writeMarker("activation", in: appGroup.syncModeRootURL)

    let adopted = appContainer.adopt(from: appGroup, diagnostics: diagnostics)

    XCTAssertEqual(adopted, appContainer)
    XCTAssertFalse(exists(appGroup.storeURL.deletingLastPathComponent()))
    XCTAssertFalse(exists(appGroup.syncModeRootURL))
    XCTAssertEqual(try readMarker("activation", in: appContainer.syncModeRootURL), "activation")
    let reopened = try SwiftDataSnipLibrary(storeURL: appContainer.storeURL)
    let snapshot = try await reopened.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(snapshot.lists.map(\.name), ["Inbox", "Work"])
    XCTAssertEqual(events, [])
  }

  func testAdoptionResumesAfterAnInterruptedMove() async throws {
    try await createList("Work", at: appContainer)
    try writeMarker("activation", in: appGroup.syncModeRootURL)

    XCTAssertEqual(appContainer.adopt(from: appGroup, diagnostics: diagnostics), appContainer)

    XCTAssertFalse(exists(appGroup.syncModeRootURL))
    XCTAssertEqual(try readMarker("activation", in: appContainer.syncModeRootURL), "activation")
    let snapshot = try await SwiftDataSnipLibrary(storeURL: appContainer.storeURL)
      .checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(snapshot.lists.map(\.name), ["Inbox", "Work"])
    XCTAssertEqual(events, [])
  }

  func testAdoptionKeepsAppContainerLibraryAndLeavesAnotherAppGroupCopyInPlace() async throws {
    try await createList("Moved", at: appContainer)
    try await createList("Recreated", at: appGroup)

    XCTAssertEqual(appContainer.adopt(from: appGroup, diagnostics: diagnostics), appContainer)

    let kept = try await SwiftDataSnipLibrary(storeURL: appContainer.storeURL)
      .checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(kept.lists.map(\.name), ["Inbox", "Moved"])
    let leftInPlace = try await SwiftDataSnipLibrary(storeURL: appGroup.storeURL)
      .checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(leftInPlace.lists.map(\.name), ["Inbox", "Recreated"])
    XCTAssertEqual(events.count, 1, "\(events)")
    XCTAssertTrue(events.allSatisfy {
      $0.contains("operation=library.relocate") && $0.contains("error=library.relocationConflict")
    })
  }

  func testDirectoryThatCannotMoveStaysInUseInAppGroup() async throws {
    try await createList("Work", at: appGroup)
    try writeMarker("activation", in: appGroup.syncModeRootURL)
    let groupRoot = appGroup.syncModeRootURL.deletingLastPathComponent()
    // The store directory can move; the sync-mode directory cannot leave a read-only parent.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: groupRoot.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: groupRoot.path)
    }

    let adopted = appContainer.adopt(from: appGroup, diagnostics: diagnostics)

    XCTAssertEqual(adopted.storeURL, appContainer.storeURL)
    XCTAssertEqual(adopted.syncModeRootURL, appGroup.syncModeRootURL)
    XCTAssertFalse(exists(appContainer.syncModeRootURL))
    XCTAssertEqual(try readMarker("activation", in: adopted.syncModeRootURL), "activation")
    let snapshot = try await SwiftDataSnipLibrary(storeURL: adopted.storeURL)
      .checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(snapshot.lists.map(\.name), ["Inbox", "Work"])
    XCTAssertEqual(events.count, 1, "\(events)")
    XCTAssertTrue(events.allSatisfy {
      $0.contains("operation=library.relocate") && $0.contains("error=posix.\(EACCES)")
    })
  }

  private func createList(_ name: String, at location: SnipLibraryLocation) async throws {
    let library = try SwiftDataSnipLibrary(storeURL: location.storeURL)
    _ = try await library.perform(
      .createList(name: name, systemImage: "list.bullet"), sortedBy: .manual)
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  private func writeMarker(_ text: String, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: directory.appendingPathComponent("marker.txt"))
  }

  private func readMarker(_ text: String, in directory: URL) throws -> String {
    String(decoding: try Data(contentsOf: directory.appendingPathComponent("marker.txt")), as: UTF8.self)
  }
}
