import Foundation
import SnipSnapCore
import XCTest

final class SnipCLIApplicationActionTests: XCTestCase {
  func testCompactedActionsRemovePrivateArgumentsAndRemainDecodable() throws {
    let actions: [SnipCLIApplicationAction] = [
      .setSetting(key: .appearance, value: "private-setting", expectedRevision: "private-revision"),
      .setShortcut(action: .merge, binding: .chord(keyCode: 46, modifiers: 768, label: "private-label"), expectedRevision: "private-revision"),
      .resetShortcut(action: .merge, expectedRevision: "private-revision"),
      .setSync(enabled: true, useCurrentCache: false, expectedRevision: "private-revision"),
      .setClipboardSync(enabled: true, expectedRevision: "private-revision"),
      .cancelSyncSetup(expectedRevision: "private-revision"),
      .resolveAccount(choice: .keep, expectedRevision: "private-revision", confirmed: false),
      .exportDiagnostics(path: "/private/export"),
      .exportDiagnostics(path: "/private/export", range: .last7Days),
      .setDiagnosticRecording(enabled: false, expectedRevision: "private-revision"),
      .clearDiagnostics(expectedRevision: "private-revision", confirmed: true),
      .clearAttachmentCache(expectedRevision: "private-revision", confirmed: true),
      .selectList(selector: "private-list"), .search(query: "private-search"),
    ]
    for action in actions {
      let data = try JSONEncoder().encode(action.compacted)
      XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
      XCTAssertEqual(try JSONDecoder().decode(SnipCLIApplicationAction.self, from: data), action.compacted)
      XCTAssertFalse(action.isReadOnly)
    }
  }

  func testOlderDiagnosticExportRequestsStillDecodeWithoutARange() throws {
    let olderRequest = Data(#"{"exportDiagnostics":{"path":"/tmp/report.txt"}}"#.utf8)
    XCTAssertEqual(try JSONDecoder().decode(SnipCLIApplicationAction.self, from: olderRequest),
                   .exportDiagnostics(path: "/tmp/report.txt"))
    let ranged = SnipCLIApplicationAction.exportDiagnostics(path: "/tmp/report.txt", range: .last7Days)
    XCTAssertEqual(try JSONDecoder().decode(SnipCLIApplicationAction.self, from: JSONEncoder().encode(ranged)), ranged)
  }

  func testOnlyStatusAndSettingsReadsAreTransient() {
    for action in [SnipCLIApplicationAction.settingsShow, .syncStatus, .clipboardSyncStatus,
                   .diagnosticsStatus, .diagnosticLogs(range: .last7Days, limit: 5, errorsOnly: true),
                   .attachmentCacheStatus, .status] {
      XCTAssertTrue(action.isReadOnly)
    }
    for action in [SnipCLIApplicationAction.captureScreen, .captureSelection, .retrySync,
                   .retryClipboardSync, .show, .hide, .checkForUpdates] {
      XCTAssertFalse(action.isReadOnly)
    }
  }

  func testRevisionIsStableAcrossDictionaryInsertionOrderAndChangesWithState() throws {
    let first = SnipCLIApplicationResult(values: ["appearance": "dark", "sort": "manual"])
    let reordered = SnipCLIApplicationResult(values: ["sort": "manual", "appearance": "dark"])
    XCTAssertEqual(first.revision, reordered.revision)
    XCTAssertNotEqual(first.revision, SnipCLIApplicationResult(values: ["appearance": "light", "sort": "manual"]).revision)
    XCTAssertEqual(try JSONDecoder().decode(SnipCLIApplicationResult.self, from: JSONEncoder().encode(first)), first)
  }

  func testStoredMutationReceiptDropsTypedSettingsPayload() throws {
    let request = SnipCLIRequest(action: .extended(.application(.search(query: "private-query"))))
    let receipt = SnipCLIReceipt(request: request, status: .success,
      extendedResult: .application(SnipCLIApplicationResult(values: ["private-key": "private-result"])))
    let compact = receipt.compacted()
    XCTAssertNil(compact.extendedResult)
    let data = try JSONEncoder().encode(compact)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
    XCTAssertTrue(try JSONDecoder().decode(SnipCLIReceipt.self, from: data).matches(request))
  }
}
