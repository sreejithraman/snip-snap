import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
import XCTest

final class MacLocalSnipLibraryMigrationTests: XCTestCase {
  private struct VersionSixDocument: Encodable {
    let version: Int
    let snips: [Snip]
    let lists: [SnipList]
    let seenRequestIDs: Set<UUID>
  }

  private struct VersionFourDocument: Encodable {
    let version: Int
    let items: [Snip]
    let sections: [SnipList]
  }

  private enum InjectedFailure: Error { case stop }

  private var roots: [URL] = []

  override func tearDownWithError() throws {
    for root in roots { try? FileManager.default.removeItem(at: root) }
    roots = []
  }

  func testVersionSixMigrationPreservesRecordsLedgerSharedAttachmentsAndRawBackup() async throws {
    let fixture = try makeVersionSixFixture()
    let rawJSON = try Data(contentsOf: fixture.jsonURL)

    let result = MacLocalSnipLibraryBootstrap.open(jsonURL: fixture.jsonURL)

    XCTAssertEqual(result.mode, .swiftData)
    XCTAssertNil(result.errorMessage)
    let backupURL = try XCTUnwrap(result.backupURL)
    XCTAssertEqual(
      try Data(contentsOf: backupURL.appendingPathComponent("snips.json")),
      rawJSON
    )
    let manifest = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: backupURL.appendingPathComponent("manifest.json"))
      ) as? [String: Any]
    )
    XCTAssertEqual(manifest["version"] as? Int, 1)
    XCTAssertEqual((manifest["files"] as? [[String: Any]])?.count, 2)
    XCTAssertTrue(
      (manifest["files"] as? [[String: Any]])?.allSatisfy {
        ($0["sha256"] as? String)?.count == 64 && ($0["byteCount"] as? Int) != nil
      } == true
    )
    XCTAssertEqual(
      try Data(
        contentsOf: backupURL.appendingPathComponent("Attachments")
          .appendingPathComponent(fixture.attachment.relativePath)
      ),
      fixture.attachmentData
    )

    let snapshot = await result.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: snapshot.snips.map { ($0.id, $0) }), fixture.snipsByID)
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: snapshot.lists.map { ($0.id, $0) }), fixture.listsByID)
    XCTAssertEqual(Set(snapshot.snips.flatMap(\.attachments).map(\.id)), [fixture.attachment.id])
    XCTAssertTrue(snapshot.snips.allSatisfy { $0.attachments == [fixture.attachment] })
    let activeAttachmentURL = try XCTUnwrap(snapshot.attachmentURLs[fixture.attachment.id])
    XCTAssertTrue(activeAttachmentURL.path.contains("/Local/Attachments/"))
    XCTAssertEqual(try Data(contentsOf: activeAttachmentURL), fixture.attachmentData)

    let duplicate = try await result.library.perform(
      .add(
        content: "Must stay deleted",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [],
        requestID: fixture.deletedRequestID,
        now: Date(timeIntervalSince1970: 900)
      ),
      sortedBy: .manual
    )
    XCTAssertEqual(duplicate.outcome, .add(.duplicate))

    let marker = try markerJSON(jsonURL: fixture.jsonURL)
    XCTAssertEqual(marker["sourceVersion"] as? Int, 6)
    XCTAssertEqual(marker["storeDirectory"] as? String, "Local")
    XCTAssertEqual(marker["storeFile"] as? String, "snips.store")
    XCTAssertEqual(marker["sourceJSONPath"] as? String, "snips.json")
    XCTAssertFalse((marker["backupPath"] as? String)?.hasPrefix("/") ?? true)
  }

  func testVersionFourItemsMigrationIsDurableAndRunsOnlyOnce() async throws {
    let root = try makeRoot()
    let jsonURL = root.appendingPathComponent("snips.json")
    let itemsURL = root.appendingPathComponent("items.json")
    let list = SnipList(id: UUID(), name: "Work", systemImage: "briefcase.fill", position: 1)
    let snip = Snip(
      id: UUID(),
      requestID: UUID(),
      createdAt: Date(timeIntervalSince1970: 100),
      updatedAt: Date(timeIntervalSince1970: 200),
      content: "Legacy",
      origin: .selection,
      source: SnipSource(applicationName: "Safari", windowTitle: "Old", url: "https://example.com"),
      listID: list.id,
      isDone: true,
      manualPosition: 12
    )
    try write(VersionFourDocument(version: 4, items: [snip], sections: [.inbox, list]), to: itemsURL)
    let rawItems = try Data(contentsOf: itemsURL)

    let first = MacLocalSnipLibraryBootstrap.open(jsonURL: jsonURL)
    XCTAssertEqual(first.mode, .swiftData)
    let firstSnapshot = await first.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(firstSnapshot.snips, [snip])
    let backup = try XCTUnwrap(first.backupURL)
    XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("items.json")), rawItems)
    XCTAssertTrue(FileManager.default.fileExists(atPath: itemsURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL.path))
    XCTAssertEqual(try markerJSON(jsonURL: jsonURL)["sourceVersion"] as? Int, 4)
    XCTAssertEqual(try markerJSON(jsonURL: jsonURL)["sourceJSONPath"] as? String, "items.json")

    try write(
      VersionSixDocument(version: 6, snips: [], lists: [.inbox], seenRequestIDs: []),
      to: jsonURL
    )
    let second = MacLocalSnipLibraryBootstrap.open(jsonURL: jsonURL)
    XCTAssertEqual(second.mode, .swiftData)
    XCTAssertNil(second.backupURL)
    let secondSnapshot = await second.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(secondSnapshot.snips, [snip])
  }

  func testFailedLegacyItemsMigrationUsesItemsAsTheJSONFallbackSource() async throws {
    let root = try makeRoot()
    let jsonURL = root.appendingPathComponent("snips.json")
    let itemsURL = root.appendingPathComponent("items.json")
    let snip = Snip(
      id: UUID(),
      requestID: UUID(),
      createdAt: Date(timeIntervalSince1970: 100),
      content: "Fallback legacy item",
      origin: .quickEntry
    )
    try write(VersionFourDocument(version: 4, items: [snip], sections: [.inbox]), to: itemsURL)

    let result = MacLocalSnipLibraryBootstrap.open(jsonURL: jsonURL) { checkpoint in
      if checkpoint == .afterArchiveRead { throw InjectedFailure.stop }
    }

    XCTAssertEqual(result.mode, .jsonFallback)
    let snapshot = await result.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(snapshot.snips.map(\.id), [snip.id])
    XCTAssertFalse(FileManager.default.fileExists(atPath: itemsURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
    XCTAssertNotNil(result.backupURL)
  }

  func testPreActivationFailureKeepsJSONActiveAndCanRetry() async throws {
    let fixture = try makeVersionSixFixture()
    let paths = LocalSnipStorePaths(jsonURL: fixture.jsonURL)

    let failed = MacLocalSnipLibraryBootstrap.open(jsonURL: fixture.jsonURL) { checkpoint in
      if checkpoint == .afterVerification { throw InjectedFailure.stop }
    }

    XCTAssertEqual(failed.mode, .jsonFallback)
    XCTAssertNotNil(failed.errorMessage)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.localDirectory.path))
    XCTAssertNotNil(failed.backupURL)
    let fallbackSnapshot = await failed.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: fallbackSnapshot.snips.map { ($0.id, $0) }), fixture.snipsByID)

    let abandoned = paths.stagingDirectory(id: UUID())
    try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
    try Data("do not delete".utf8).write(to: abandoned.appendingPathComponent("sentinel"))

    let retried = MacLocalSnipLibraryBootstrap.open(jsonURL: fixture.jsonURL)
    XCTAssertEqual(retried.mode, .swiftData)
    XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    let retriedSnapshot = await retried.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: retriedSnapshot.snips.map { ($0.id, $0) }),
      fixture.snipsByID
    )
  }

  func testJSONChangeAtFinalActivationCheckpointAbortsMigration() async throws {
    let fixture = try makeVersionSixFixture()
    let paths = LocalSnipStorePaths(jsonURL: fixture.jsonURL)
    let lateSnip = Snip(
      id: UUID(),
      requestID: UUID(),
      createdAt: Date(timeIntervalSince1970: 800),
      content: "Arrived during migration",
      origin: .quickEntry
    )

    let result = MacLocalSnipLibraryBootstrap.open(jsonURL: fixture.jsonURL) { checkpoint in
      guard checkpoint == .beforeActivation else { return }
      try self.write(
        VersionSixDocument(
          version: 6,
          snips: Array(fixture.snipsByID.values) + [lateSnip],
          lists: Array(fixture.listsByID.values),
          seenRequestIDs: Set(fixture.snipsByID.values.map(\.requestID)).union([lateSnip.requestID])
        ),
        to: fixture.jsonURL
      )
    }

    XCTAssertEqual(result.mode, .jsonFallback)
    XCTAssertTrue(result.errorMessage?.contains("changed") == true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.localDirectory.path))
    let snapshot = await result.library.snapshot(sortedBy: .manual)
    XCTAssertTrue(snapshot.snips.contains(where: { $0.id == lateSnip.id }))
  }

  func testAttachmentChangeAtFinalActivationCheckpointAbortsMigration() async throws {
    let fixture = try makeVersionSixFixture()
    let paths = LocalSnipStorePaths(jsonURL: fixture.jsonURL)
    let attachmentURL = paths.legacyAttachmentDirectory
      .appendingPathComponent(fixture.attachment.relativePath)
    let changedBytes = Data(repeating: 0x78, count: fixture.attachmentData.count)

    let result = MacLocalSnipLibraryBootstrap.open(jsonURL: fixture.jsonURL) { checkpoint in
      guard checkpoint == .beforeActivation else { return }
      try changedBytes.write(to: attachmentURL, options: .atomic)
    }

    XCTAssertEqual(result.mode, .jsonFallback)
    XCTAssertTrue(result.errorMessage?.contains("attachment") == true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.localDirectory.path))
    let snapshot = await result.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: snapshot.snips.map { ($0.id, $0) }),
      fixture.snipsByID
    )
  }

  func testFinalStoreOpenFailureRollsActivationBackBeforeJSONFallback() async throws {
    let fixture = try makeVersionSixFixture()
    let paths = LocalSnipStorePaths(jsonURL: fixture.jsonURL)

    let result = MacLocalSnipLibraryBootstrap.open(
      jsonURL: fixture.jsonURL,
      checkpoint: { _ in },
      libraryFactory: { storeURL in
        if storeURL == paths.swiftDataStoreURL { throw InjectedFailure.stop }
        return try SwiftDataSnipLibrary(storeURL: storeURL)
      }
    )

    XCTAssertEqual(result.mode, .jsonFallback)
    XCTAssertNotNil(result.errorMessage)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.localDirectory.path))
    let snapshot = await result.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: snapshot.snips.map { ($0.id, $0) }),
      fixture.snipsByID
    )
  }

  func testChangedStagedAttachmentFailsHashCheckAndLeavesJSONActive() async throws {
    let fixture = try makeVersionSixFixture()
    let paths = LocalSnipStorePaths(jsonURL: fixture.jsonURL)
    let result = MacLocalSnipLibraryBootstrap.open(jsonURL: fixture.jsonURL) { checkpoint in
      guard checkpoint == .afterStageImport else { return }
      let stage = try XCTUnwrap(
        FileManager.default.contentsOfDirectory(
          at: paths.rootDirectory,
          includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix("Local.importing-") }
      )
      let attachmentURL = stage.appendingPathComponent("Attachments")
        .appendingPathComponent(fixture.attachment.relativePath)
      try Data("changed".utf8).write(to: attachmentURL, options: .atomic)
    }

    XCTAssertEqual(result.mode, .jsonFallback)
    XCTAssertTrue(result.errorMessage?.contains("attachment") == true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.localDirectory.path))
    let fallbackSnapshot = await result.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: fallbackSnapshot.snips.map { ($0.id, $0) }),
      fixture.snipsByID
    )
  }

  func testMissingAttachmentFailsWithoutActivatingSwiftData() async throws {
    let fixture = try makeVersionSixFixture()
    let paths = LocalSnipStorePaths(jsonURL: fixture.jsonURL)
    try FileManager.default.removeItem(at: paths.legacyAttachmentDirectory)

    let result = MacLocalSnipLibraryBootstrap.open(jsonURL: fixture.jsonURL)

    XCTAssertEqual(result.mode, .jsonFallback)
    XCTAssertTrue(result.errorMessage?.contains("missing attachment") == true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.localDirectory.path))
    XCTAssertNotNil(result.backupURL)
  }

  func testUnmarkedFinalLocalDirectoryIsNeverDeletedOrReplaced() throws {
    let fixture = try makeVersionSixFixture()
    let paths = LocalSnipStorePaths(jsonURL: fixture.jsonURL)
    try FileManager.default.createDirectory(at: paths.localDirectory, withIntermediateDirectories: false)
    let sentinel = paths.localDirectory.appendingPathComponent("sentinel")
    try Data("keep".utf8).write(to: sentinel)

    let result = MacLocalSnipLibraryBootstrap.open(jsonURL: fixture.jsonURL)

    XCTAssertEqual(result.mode, .jsonFallback)
    XCTAssertTrue(result.errorMessage?.contains("without a valid migration marker") == true)
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.markerURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.swiftDataStoreURL.path))
  }

  func testRetryCleansOnlyKnownIncompleteWorkNames() throws {
    let root = try makeRoot()
    let jsonURL = root.appendingPathComponent("snips.json")
    let paths = LocalSnipStorePaths(jsonURL: jsonURL)
    let staleStage = paths.stagingDirectory(id: UUID())
    let ambiguousStage = root.appendingPathComponent("Local.importing-not-a-uuid")
    try FileManager.default.createDirectory(at: staleStage, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: ambiguousStage, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(
      at: paths.backupRootDirectory,
      withIntermediateDirectories: false
    )
    let staleBackup = paths.backupRootDirectory.appendingPathComponent(
      "JSON-to-SwiftData-\(UUID().uuidString).building", isDirectory: true)
    let ambiguousBackup = paths.backupRootDirectory.appendingPathComponent(
      "JSON-to-SwiftData-not-a-uuid.building", isDirectory: true)
    try FileManager.default.createDirectory(at: staleBackup, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: ambiguousBackup, withIntermediateDirectories: false)

    let result = MacLocalSnipLibraryBootstrap.open(jsonURL: jsonURL)

    XCTAssertEqual(result.mode, .swiftData)
    XCTAssertFalse(FileManager.default.fileExists(atPath: staleStage.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: staleBackup.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: ambiguousStage.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: ambiguousBackup.path))
  }

  func testCorruptJSONIsBackedUpBeforeExistingRecoveryStartsANewJSONStore() async throws {
    let root = try makeRoot()
    let jsonURL = root.appendingPathComponent("snips.json")
    let corruptData = Data("{not valid json".utf8)
    try corruptData.write(to: jsonURL)

    let result = MacLocalSnipLibraryBootstrap.open(jsonURL: jsonURL)

    XCTAssertEqual(result.mode, .jsonFallback)
    XCTAssertTrue(result.errorMessage?.contains("unreadable JSON") == true)
    let rawBackup = try XCTUnwrap(result.backupURL)
    XCTAssertEqual(try Data(contentsOf: rawBackup.appendingPathComponent("snips.json")), corruptData)
    XCTAssertTrue(FileManager.default.fileExists(atPath: rawBackup.appendingPathComponent("manifest.json").path))
    let corruptCopies = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("snips.corrupt-") }
    XCTAssertEqual(corruptCopies.count, 1)
    XCTAssertEqual(try Data(contentsOf: corruptCopies[0]), corruptData)
    let snapshot = await result.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(snapshot.snips, [])
  }

  func testNewInstallCreatesMarkedSwiftDataStoreWithoutJSON() async throws {
    let root = try makeRoot()
    let jsonURL = root.appendingPathComponent("snips.json")
    let result = MacLocalSnipLibraryBootstrap.open(jsonURL: jsonURL)

    XCTAssertEqual(result.mode, .swiftData)
    XCTAssertNil(result.backupURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL.path))
    let snapshot = await result.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(snapshot.lists, [.inbox])
    XCTAssertEqual(try markerJSON(jsonURL: jsonURL)["sourceJSONPath"] as? String, "snips.json")
    XCTAssertNil(try markerJSON(jsonURL: jsonURL)["backupPath"])
  }

  func testNewInstallCreatesMissingStoreRootBeforeStaging() async throws {
    let base = try makeRoot()
    let missingRoot = base.appendingPathComponent("Missing/Application Support/Snip Snap")
    let jsonURL = missingRoot.appendingPathComponent("snips.json")
    XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot.path))

    let result = MacLocalSnipLibraryBootstrap.open(jsonURL: jsonURL)

    XCTAssertEqual(result.mode, .swiftData)
    XCTAssertNil(result.errorMessage)
    let paths = LocalSnipStorePaths(jsonURL: jsonURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.swiftDataStoreURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.markerURL.path))
    let snapshot = await result.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(snapshot.lists, [.inbox])
  }

  func testDeletingACompletedBackupDoesNotSwitchTheLiveStoreBackToJSON() async throws {
    let fixture = try makeVersionSixFixture()
    let first = MacLocalSnipLibraryBootstrap.open(jsonURL: fixture.jsonURL)
    XCTAssertEqual(first.mode, .swiftData)
    try FileManager.default.removeItem(at: XCTUnwrap(first.backupURL))

    let second = MacLocalSnipLibraryBootstrap.open(jsonURL: fixture.jsonURL)

    XCTAssertEqual(second.mode, .swiftData)
    let snapshot = await second.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: snapshot.snips.map { ($0.id, $0) }), fixture.snipsByID)
  }

  func testMissingActivatedSwiftDataStoreDoesNotFallBackToStaleJSON() throws {
    let fixture = try makeVersionSixFixture()
    let first = MacLocalSnipLibraryBootstrap.open(jsonURL: fixture.jsonURL)
    XCTAssertEqual(first.mode, .swiftData)
    let paths = LocalSnipStorePaths(jsonURL: fixture.jsonURL)
    try FileManager.default.removeItem(at: paths.swiftDataStoreURL)

    let second = MacLocalSnipLibraryBootstrap.open(jsonURL: fixture.jsonURL)

    XCTAssertEqual(second.mode, .unavailable)
    XCTAssertTrue(second.errorMessage?.contains("could not open its SwiftData store") == true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.swiftDataStoreURL.path))
  }

  func testJSONTransferExportsTheLiveSwiftDataStoreAndImportsByMerging() async throws {
    let root = try makeRoot()
    let sourceStore = root.appendingPathComponent("Source/Local/snips.store")
    let source = try SwiftDataSnipLibrary(storeURL: sourceStore)
    let listUpdate = try await source.perform(
      .createList(name: "Imported List", systemImage: "star.fill"),
      sortedBy: .manual
    )
    guard case .listCreated(let importedList) = listUpdate.outcome else {
      return XCTFail("Expected a created list")
    }
    let attachmentSource = root.appendingPathComponent("transfer.txt")
    let attachmentData = Data("transfer attachment".utf8)
    try attachmentData.write(to: attachmentSource)
    let liveRequestID = UUID()
    _ = try await source.perform(
      .add(
        content: "Exported live snip",
        origin: .selection,
        source: SnipSource(
          applicationName: "Safari",
          windowTitle: "Transfer",
          url: "https://example.com/transfer"
        ),
        listID: importedList.id,
        attachmentURLs: [attachmentSource],
        requestID: liveRequestID,
        now: Date(timeIntervalSince1970: 300)
      ),
      sortedBy: .manual
    )
    let deletedRequestID = UUID()
    let deleted = try await source.perform(
      .add(
        content: "Deleted before export",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [],
        requestID: deletedRequestID,
        now: Date(timeIntervalSince1970: 200)
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let deletedID)) = deleted.outcome else {
      return XCTFail("Expected an added snip")
    }
    _ = try await source.perform(.delete(ids: [deletedID]), sortedBy: .manual)

    let exportDirectory = root.appendingPathComponent("Snip Snap Backup", isDirectory: true)
    let sourceArchive = try await source.archive()
    let directArchive = try SwiftDataSnipLibrary.readArchive(storeURL: sourceStore)
    XCTAssertTrue(directArchive.seenRequestIDs.contains(deletedRequestID))
    XCTAssertTrue(sourceArchive.seenRequestIDs.contains(deletedRequestID))
    try JSONSnipArchiveTransfer.write(sourceArchive, to: exportDirectory)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: exportDirectory.appendingPathComponent("snips.json").path
      )
    )

    let destinationStore = root.appendingPathComponent("Destination/Local/snips.store")
    let destination = try SwiftDataSnipLibrary(storeURL: destinationStore)
    let existingRequestID = UUID()
    _ = try await destination.perform(
      .add(
        content: "Keep existing",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [],
        requestID: existingRequestID,
        now: Date(timeIntervalSince1970: 400)
      ),
      sortedBy: .manual
    )
    let imported = try JSONSnipArchiveTransfer.read(from: exportDirectory)
    XCTAssertTrue(imported.seenRequestIDs.contains(deletedRequestID))
    _ = try await destination.perform(.importArchive(imported), sortedBy: .manual)
    let destinationArchive = try await destination.archive()
    XCTAssertTrue(destinationArchive.seenRequestIDs.contains(deletedRequestID))

    let snapshot = await destination.snapshot(sortedBy: .manual)
    XCTAssertEqual(Set(snapshot.snips.map(\.content)), ["Keep existing", "Exported live snip"])
    XCTAssertTrue(snapshot.lists.contains(where: { $0.id == importedList.id }))
    let importedSnip = try XCTUnwrap(snapshot.snips.first { $0.requestID == liveRequestID })
    XCTAssertEqual(importedSnip.source?.windowTitle, "Transfer")
    let importedAttachment = try XCTUnwrap(importedSnip.attachments.first)
    XCTAssertEqual(
      try Data(contentsOf: XCTUnwrap(snapshot.attachmentURLs[importedAttachment.id])),
      attachmentData
    )
    let replay = try await destination.perform(
      .add(
        content: "Must remain deleted",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [],
        requestID: deletedRequestID,
        now: Date(timeIntervalSince1970: 500)
      ),
      sortedBy: .manual
    )
    XCTAssertEqual(replay.outcome, .add(.duplicate))
  }

  func testJSONImportRejectsAttachmentSymlinkOutsideSelectedAttachments() throws {
    let fixture = try makeVersionSixFixture()
    let paths = LocalSnipStorePaths(jsonURL: fixture.jsonURL)
    let attachmentParent = paths.legacyAttachmentDirectory
      .appendingPathComponent(fixture.attachment.relativePath)
      .deletingLastPathComponent()
    try FileManager.default.removeItem(at: attachmentParent)
    let escapedDirectory = paths.rootDirectory.appendingPathComponent("Escaped")
    try FileManager.default.createDirectory(
      at: escapedDirectory,
      withIntermediateDirectories: false
    )
    try fixture.attachmentData.write(
      to: escapedDirectory.appendingPathComponent(fixture.attachment.fileName)
    )
    try FileManager.default.createSymbolicLink(
      at: attachmentParent,
      withDestinationURL: escapedDirectory
    )

    XCTAssertThrowsError(try JSONSnipArchiveTransfer.read(from: paths.rootDirectory))
  }

  private struct VersionSixFixture {
    let jsonURL: URL
    let attachment: SnipAttachment
    let attachmentData: Data
    let snipsByID: [UUID: Snip]
    let listsByID: [UUID: SnipList]
    let deletedRequestID: UUID
  }

  private func makeVersionSixFixture() throws -> VersionSixFixture {
    let root = try makeRoot()
    let jsonURL = root.appendingPathComponent("snips.json")
    let attachmentID = UUID()
    let relativePath = "\(attachmentID.uuidString)/shared.txt"
    let attachmentData = Data("shared attachment bytes".utf8)
    let attachment = SnipAttachment(
      id: attachmentID,
      fileName: "shared.txt",
      relativePath: relativePath,
      contentType: "public.plain-text",
      byteCount: Int64(attachmentData.count)
    )
    let attachmentURL = root.appendingPathComponent("Attachments")
      .appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: attachmentURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try attachmentData.write(to: attachmentURL)
    let list = SnipList(id: UUID(), name: "Research", systemImage: "book.fill", position: 1)
    let first = Snip(
      id: UUID(),
      requestID: UUID(),
      createdAt: Date(timeIntervalSince1970: 100),
      updatedAt: Date(timeIntervalSince1970: 150),
      content: "First",
      origin: .selection,
      source: SnipSource(applicationName: "Safari", windowTitle: "Source", url: "https://example.com/a"),
      listID: list.id,
      isDone: false,
      manualPosition: 8,
      attachments: [attachment]
    )
    let second = Snip(
      id: UUID(),
      requestID: UUID(),
      createdAt: Date(timeIntervalSince1970: 200),
      updatedAt: Date(timeIntervalSince1970: 250),
      content: "Second",
      origin: .clipboard,
      source: SnipSource(applicationName: "Notes", windowTitle: nil, url: nil),
      listID: SnipList.inboxID,
      isDone: true,
      manualPosition: -4,
      attachments: [attachment]
    )
    let deletedRequestID = UUID()
    try write(
      VersionSixDocument(
        version: 6,
        snips: [second, first],
        lists: [list, .inbox],
        seenRequestIDs: [first.requestID, second.requestID, deletedRequestID]
      ),
      to: jsonURL
    )
    return VersionSixFixture(
      jsonURL: jsonURL,
      attachment: attachment,
      attachmentData: attachmentData,
      snipsByID: [first.id: first, second.id: second],
      listsByID: [SnipList.inboxID: .inbox, list.id: list],
      deletedRequestID: deletedRequestID
    )
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SnipSnapMacMigrationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    roots.append(root)
    return root
  }

  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: .atomic)
  }

  private func markerJSON(jsonURL: URL) throws -> [String: Any] {
    let markerURL = LocalSnipStorePaths(jsonURL: jsonURL).markerURL
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
    )
  }
}
