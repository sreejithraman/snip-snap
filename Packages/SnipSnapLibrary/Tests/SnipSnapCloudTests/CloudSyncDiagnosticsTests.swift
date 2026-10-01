import CloudKit
import Foundation
import XCTest

@testable import SnipSnapCloud
@testable import SnipSnapCore
@testable import SnipSnapPersistence

final class CloudSyncDiagnosticsTests: XCTestCase {
  func testRecoveredStagedFetchAndSendReportSuccessfulCommittedTransfers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account",
      generation: UUID(), zones: [zone])
    let server = FakeCloudServer()
    await server.createZones([zone])
    let snip = Snip(content: "private staged content", origin: .quickEntry)
    let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
    _ = try await writer.send(CloudOutboundBatch(operations: [
      .save(try CloudFullRecordCodec.listDraft(.inbox, updatedAt: Date(timeIntervalSince1970: 0), in: zone)),
      .save(try CloudFullRecordCodec.snipDraft(snip, in: zone))
    ]))
    let reader = FakeCloudRecordTransport(server: server, namespace: namespace)
    try await reader.start(state: nil)
    let fetched = try await reader.fetch(scope: .all)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let probe = SyncDiagnosticProbe()
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone,
      diagnostics: probe.recorder)
    // Simulate interruption after durable staging but before applying the fetched batch.
    try await store.stage(.fetched(fetched), outbound: nil)
    let recovered = CloudFullSyncCoordinator(store: store,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace), diagnostics: probe.recorder)
    _ = try await recovered.processAutomaticChanges()
    let imported = try await library.snapshot(sortedBy: .manual)
    XCTAssertTrue(imported.snips.contains { $0.id == snip.id })
    XCTAssertTrue(probe.events.contains { $0.operation == "sync.fetch" && $0.outcome == .succeeded })

    _ = try await library.perform(.update(id: snip.id, content: "private staged edit", attachmentURLs: nil,
      expectedUpdatedAt: snip.updatedAt, now: snip.updatedAt.addingTimeInterval(1)), sortedBy: .manual)
    let outbound = try await store.pendingChanges()
    XCTAssertFalse(outbound.operations.isEmpty)
    let sender = FakeCloudRecordTransport(server: server, namespace: namespace)
    try await sender.start(state: store.loadEngineState())
    let sent = try await sender.send(outbound)
    try await store.stage(.sent(sent), outbound: outbound)
    _ = try await recovered.processAutomaticChanges()
    XCTAssertTrue(probe.events.contains { $0.operation == "sync.send" && $0.outcome == .succeeded })
    XCTAssertFalse(probe.events.map(\.line).joined().contains("private staged"))
  }

  func testFailedLocalCommitDoesNotReportFetchSuccess() async throws {
    struct CommitFailure: Error {}
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account",
      generation: UUID(), zones: [zone])
    let server = FakeCloudServer()
    await server.createZones([zone])
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let probe = SyncDiagnosticProbe()
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone,
      diagnostics: probe.recorder, afterCommitHook: { throw CommitFailure() })
    let coordinator = CloudFullSyncCoordinator(store: store,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace), diagnostics: probe.recorder)

    do {
      _ = try await coordinator.fetchRemote()
      XCTFail("Expected the local commit failure")
    } catch is CommitFailure {}

    XCTAssertTrue(probe.events.contains { $0.operation == "sync.fetch" && $0.outcome == .failed })
    XCTAssertFalse(probe.events.contains { $0.operation == "sync.fetch" && $0.outcome == .succeeded })
  }

  func testDestructiveResetReportsRecoveryBlockedInsteadOfPendingWork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account",
      generation: UUID(), zones: [zone])
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let probe = SyncDiagnosticProbe()
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone,
      diagnostics: probe.recorder)
    let reset = CloudFetchedBatch(id: UUID(), items: [],
      databaseEvents: [.zoneDeleted(zone, reason: .purged)], engineState: nil)
    try await store.stage(.fetched(reset), outbound: nil)
    try await store.applyStaged(reset.id)
    let coordinator = CloudFullSyncCoordinator(store: store,
      transport: FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace),
      diagnostics: probe.recorder)

    let outcome = try await coordinator.processAutomaticChanges()

    XCTAssertEqual(outcome.result, .iCloudDataReset)
    XCTAssertTrue(outcome.blocksOutbound)
    XCTAssertFalse(outcome.settled)
    let settlement = try XCTUnwrap(probe.events.last { $0.operation == "sync.settlement" })
    XCTAssertEqual(settlement.syncReason, .recoveryBlocked)
  }

  func testCommittedRecordWorkReportsProgressAndObservedPendingCounts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let zone = CloudZoneID(name: "private-zone", ownerName: "private-owner")
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "private-account",
      generation: UUID(), zones: [zone])
    let server = FakeCloudServer()
    await server.createZones([zone])
    let snip = Snip(content: "private original", origin: .quickEntry)
    let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
    _ = try await writer.send(CloudOutboundBatch(operations: [
      .save(try CloudFullRecordCodec.listDraft(.inbox, updatedAt: Date(timeIntervalSince1970: 0), in: zone)),
      .save(try CloudFullRecordCodec.snipDraft(snip, in: zone))
    ]))
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let probe = SyncDiagnosticProbe()
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone,
      diagnostics: probe.recorder)
    let coordinator = CloudFullSyncCoordinator(store: store,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace), diagnostics: probe.recorder)

    _ = try await coordinator.fetchRemote()
    _ = try await library.perform(.update(id: snip.id, content: "private content", attachmentURLs: nil,
      expectedUpdatedAt: snip.updatedAt, now: snip.updatedAt.addingTimeInterval(1)), sortedBy: .manual)
    let outcome = try await coordinator.sendPendingUntilSettled()

    XCTAssertTrue(outcome.settled)
    let events = probe.events
    XCTAssertTrue(events.contains { $0.operation == "sync.fetch" && $0.outcome == .succeeded })
    XCTAssertTrue(events.contains { $0.operation == "sync.send" && $0.outcome == .succeeded })
    XCTAssertTrue(events.contains { $0.syncScope == .records && ($0.pendingUploads ?? 0) > 0 })
    let latest = try XCTUnwrap(events.last { $0.syncScope == .records })
    XCTAssertEqual(latest.syncPhase, .active)
    XCTAssertEqual(latest.pendingUploads, 0)
    XCTAssertFalse(events.map(\.line).joined().contains("private-"))
    XCTAssertFalse(events.map(\.line).joined().contains("private content"))
  }
  func testAttachmentErrorCodeClassifiesKnownFailuresWithoutErrorDescriptions() {
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(CKError(.assetNotAvailable)),
      "cloudkit.\(CKError.Code.assetNotAvailable.rawValue)"
    )
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(CloudAttachmentStorageError.hashMismatch),
      "storage.hashMismatch"
    )
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(
        CloudAttachmentStorageError.symbolicLinkDescendant
      ),
      "storage.symbolicLinkDescendant"
    )
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(CloudRecordError.missingAsset),
      "record.missingAsset"
    )
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(CloudTransportError.fetchFailed),
      "transport.fetchFailed"
    )
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(CocoaError(.fileReadNoSuchFile)),
      "cocoa.\(CocoaError.Code.fileReadNoSuchFile.rawValue)"
    )
  }

  func testAttachmentErrorCodeDoesNotIncludeUnknownErrorDescription() {
    struct PrivateFailure: LocalizedError {
      let errorDescription: String? = "private file name and path"
    }

    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(PrivateFailure()),
      "other.PrivateFailure"
    )
  }

  func testAttachmentErrorCodeClassifiesSnipLibraryFailures() {
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(SnipLibraryError.storeUnavailable),
      "library.storeUnavailable"
    )
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(SnipLibraryError.invalidStore),
      "library.invalidStore"
    )
    XCTAssertEqual(
      CloudSyncDiagnostics.attachmentErrorCode(SnipLibraryError.attachmentCopyFailed),
      "library.attachmentCopyFailed"
    )
  }

}

private final class SyncDiagnosticProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [AppDiagnosticEvent] = []
  var recorder: AppDiagnosticRecorder {
    AppDiagnosticRecorder { [self] event in lock.withLock { stored.append(event) } }
  }
  var events: [AppDiagnosticEvent] { lock.withLock { stored } }
}
