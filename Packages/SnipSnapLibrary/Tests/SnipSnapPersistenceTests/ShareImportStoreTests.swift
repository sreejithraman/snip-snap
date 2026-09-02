import Foundation
import SnipSnapCore
import SwiftData
@testable import SnipSnapPersistence
import XCTest

final class ShareImportStoreTests: XCTestCase {
  func testPendingShareWaitsForStoreMigrationThenImportsOnceAcrossRelaunch() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = ShareImportStore.storeURL(in: root)
    try FileManager.default.createDirectory(
      at: storeURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    do {
      let schema = Schema(versionedSchema: SnipSnapSchemaV2.self)
      let configuration = ModelConfiguration(
        "BeforeShareSync",
        schema: schema,
        url: storeURL,
        cloudKitDatabase: .none
      )
      let container = try ModelContainer(for: schema, configurations: [configuration])
      let context = ModelContext(container)
      context.insert(StoredListRecord(.inbox))
      try context.save()
    }
    let requestID = UUID()
    let imports = ShareImportStore(sharedRootURL: root)
    _ = try await imports.save(
      ShareImportRequest(
        content: "Wait for migration",
        destinationListID: SnipList.inbox.id,
        requestID: requestID
      )
    )
    let pendingBeforeMigration = await imports.pendingImportCount()
    XCTAssertEqual(pendingBeforeMigration, 1)

    let migrated = try SwiftDataSnipLibrary(storeURL: storeURL)
    let firstImport = await imports.importPending(into: migrated)
    XCTAssertEqual(firstImport, ShareImportSummary(imported: 1, failed: 0))

    let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)
    let repeatedImport = await imports.importPending(into: reopened)
    XCTAssertEqual(repeatedImport, ShareImportSummary(imported: 0, failed: 0))
    let snapshot = await reopened.snapshot(sortedBy: .chronological)
    XCTAssertEqual(snapshot.snips.map(\.requestID), [requestID])
    XCTAssertEqual(snapshot.snips.map(\.content), ["Wait for migration"])
  }

  func testAppGroupContainerUsesOneValidatedIdentifierLookup() {
    let expected = URL(fileURLWithPath: "/tmp/shared-container", isDirectory: true)
    var resolvedIdentifiers: [String] = []
    let resolve: (String) -> URL? = { identifier in
      resolvedIdentifiers.append(identifier)
      return expected
    }

    XCTAssertNil(
      SnipSnapAppGroupContainer.resolve(appGroupIdentifier: nil, resolveURL: resolve)
    )
    XCTAssertNil(
      SnipSnapAppGroupContainer.resolve(appGroupIdentifier: "   ", resolveURL: resolve)
    )
    let container = SnipSnapAppGroupContainer.resolve(
        appGroupIdentifier: "  group.org.example.snipsnap  ",
        resolveURL: resolve
    )
    XCTAssertEqual(container?.identifier, "group.org.example.snipsnap")
    XCTAssertEqual(container?.url, expected)
    XCTAssertEqual(resolvedIdentifiers, ["group.org.example.snipsnap"])
  }

  func testOrdinaryStoreDoesNotPublishShareCatalogOutsideItsLayout() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("Outside", isDirectory: true)
      .appendingPathComponent("Local", isDirectory: true)
      .appendingPathComponent("snips.store", isDirectory: false)

    _ = try SwiftDataSnipLibrary(storeURL: storeURL)

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Share/destinations.json").path
      )
    )
  }

  func testShareDestinationStartsInInboxThenUsesAStillPresentRememberedList() {
    let reading = SnipList(id: UUID(), name: "Reading", systemImage: "list.bullet", position: 1)
    let lists: [SnipList] = [.inbox, reading]

    XCTAssertEqual(
      SnipShareDestination.resolve(rememberedListID: nil, in: lists),
      SnipList.inboxID
    )
    XCTAssertEqual(
      SnipShareDestination.resolve(rememberedListID: reading.id, in: lists),
      reading.id
    )
    XCTAssertEqual(
      SnipShareDestination.resolve(rememberedListID: UUID(), in: lists),
      SnipList.inboxID
    )
  }

  func testProviderFileCopySurvivesTheProviderTemporaryFile() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("provider-file.txt")
    try Data("provider bytes".utf8).write(to: sourceURL)
    let staging = try ShareImportStagingArea(sharedRootURL: root)

    let attachment = try staging.copyProviderFile(
      at: sourceURL,
      contentType: "public.plain-text"
    )
    try FileManager.default.removeItem(at: sourceURL)

    XCTAssertFalse(attachment.relativePath.hasPrefix("/"))
    XCTAssertEqual(attachment.fileName, "provider-file.txt")
  }

  func testProviderCallbackCopiesTheFileBeforeTheCallbackReturns() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("callback-file.txt")
    try Data("callback bytes".utf8).write(to: sourceURL)
    let staging = try ShareImportStagingArea(sharedRootURL: root)

    let attachment = try await ShareProviderFileLoader.copyFileRepresentation(
      staging: staging,
      suggestedName: "callback-file.txt",
      contentType: "public.plain-text"
    ) { completion in
      completion(sourceURL, nil)
      try? FileManager.default.removeItem(at: sourceURL)
    }
    let imports = ShareImportStore(sharedRootURL: root)
    _ = try await imports.save(
      ShareImportRequest(
        content: "Callback",
        destinationListID: SnipList.inboxID,
        attachments: [attachment],
        requestID: staging.requestID
      )
    )
    let library = try SwiftDataSnipLibrary(storeURL: ShareImportStore.storeURL(in: root))

    let importSummary = await imports.importPending(into: library)
    XCTAssertEqual(importSummary, ShareImportSummary(imported: 1, failed: 0))
    let snapshot = await library.snapshot(sortedBy: .chronological)
    let storedAttachmentID = try XCTUnwrap(snapshot.snips.first?.attachments.first?.id)
    let storedURL = try XCTUnwrap(snapshot.attachmentURLs[storedAttachmentID])
    XCTAssertEqual(try Data(contentsOf: storedURL), Data("callback bytes".utf8))
  }

  func testSaveRejectsAnAttachmentPathOutsideItsRequestDirectory() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = try ShareImportStagingArea(sharedRootURL: root)
    let outsideURL = root.appendingPathComponent("outside.txt")
    try Data("outside".utf8).write(to: outsideURL)
    let request = ShareImportRequest(
      content: "Bad path",
      destinationListID: SnipList.inboxID,
      attachments: [
        ShareImportAttachment(
          fileName: "outside.txt",
          contentType: "public.plain-text",
          byteCount: 7,
          relativePath: "../../../../outside.txt"
        )
      ],
      requestID: staging.requestID
    )

    do {
      _ = try await ShareImportStore(sharedRootURL: root).save(request)
      XCTFail("An attachment path must stay inside its request directory.")
    } catch {
      XCTAssertEqual(error as? ShareImportError, .invalidStaging)
    }
  }

  func testSaveRejectsAnAttachmentPathThroughASymbolicLink() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = try ShareImportStagingArea(sharedRootURL: root)
    let requestDirectory = ShareImportPaths(rootURL: root)
      .intakeDirectory(requestID: staging.requestID)
    let filesDirectory = requestDirectory.appendingPathComponent("Files", isDirectory: true)
    let actualDirectory = filesDirectory.appendingPathComponent("Actual", isDirectory: true)
    try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: true)
    try Data("linked".utf8).write(
      to: actualDirectory.appendingPathComponent("linked.txt")
    )
    try FileManager.default.createSymbolicLink(
      at: filesDirectory.appendingPathComponent("Alias"),
      withDestinationURL: actualDirectory
    )
    let request = ShareImportRequest(
      content: "Bad link",
      destinationListID: SnipList.inboxID,
      attachments: [
        ShareImportAttachment(
          fileName: "linked.txt",
          contentType: "public.plain-text",
          byteCount: 6,
          relativePath: "Files/Alias/linked.txt"
        )
      ],
      requestID: staging.requestID
    )

    do {
      _ = try await ShareImportStore(sharedRootURL: root).save(request)
      XCTFail("An attachment path cannot contain a symbolic link.")
    } catch {
      XCTAssertEqual(error as? ShareImportError, .invalidStaging)
    }
  }

  func testImportRejectsAReadyDirectoryThatIsASymbolicLink() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = try ShareImportStagingArea(sharedRootURL: root)
    let imports = ShareImportStore(sharedRootURL: root)
    _ = try await imports.save(
      ShareImportRequest(
        content: "Linked request",
        destinationListID: SnipList.inboxID,
        requestID: staging.requestID
      )
    )
    let paths = ShareImportPaths(rootURL: root)
    let readyURL = paths.pendingDirectory(requestID: staging.requestID)
    let outsideURL = root.appendingPathComponent("outside.ready", isDirectory: true)
    try FileManager.default.moveItem(at: readyURL, to: outsideURL)
    try FileManager.default.createSymbolicLink(at: readyURL, withDestinationURL: outsideURL)
    let library = try SwiftDataSnipLibrary(storeURL: ShareImportStore.storeURL(in: root))

    let summary = await imports.importPending(into: library)
    let pendingCount = await imports.pendingImportCount()
    let snapshot = await library.snapshot(sortedBy: .chronological)

    XCTAssertEqual(summary, ShareImportSummary(imported: 0, failed: 0))
    XCTAssertEqual(pendingCount, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
    XCTAssertTrue(snapshot.snips.isEmpty)
  }

  func testCanceledShareDiscardsItsIntakeDirectory() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = try ShareImportStagingArea(sharedRootURL: root)
    let requestDirectory = ShareImportPaths(rootURL: root)
      .intakeDirectory(requestID: staging.requestID)
    XCTAssertTrue(FileManager.default.fileExists(atPath: requestDirectory.path))

    staging.discard()

    XCTAssertFalse(FileManager.default.fileExists(atPath: requestDirectory.path))
  }

  func testAbandonedIntakeSweepKeepsRecentShares() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let abandoned = try ShareImportStagingArea(sharedRootURL: root)
    let recent = try ShareImportStagingArea(sharedRootURL: root)
    let paths = ShareImportPaths(rootURL: root)
    let abandonedURL = paths.intakeDirectory(requestID: abandoned.requestID)
    let recentURL = paths.intakeDirectory(requestID: recent.requestID)
    let now = Date(timeIntervalSince1970: 2_000_000)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-7_200)],
      ofItemAtPath: abandonedURL.path
    )
    try FileManager.default.setAttributes(
      [.modificationDate: now],
      ofItemAtPath: recentURL.path
    )

    let removed = await ShareImportStore(sharedRootURL: root)
      .removeAbandonedIntake(olderThan: now.addingTimeInterval(-3_600))

    XCTAssertEqual(removed, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path))
  }

  func testFirstShareCreatesTheWholeDurableInboxLayout() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShareImportFirstUse-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    let staging = try ShareImportStagingArea(sharedRootURL: root)

    _ = try await ShareImportStore(sharedRootURL: root).save(
      ShareImportRequest(
        content: "First use",
        destinationListID: SnipList.inboxID,
        requestID: staging.requestID
      )
    )

    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: ShareImportPaths(rootURL: root)
          .pendingDirectory(requestID: staging.requestID).path
      )
    )
  }

  func testEverySaveWaitsInTheAtomicInboxUntilTheMainAppImportsIt() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = ShareImportStore.storeURL(in: root)
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let listUpdate = try await library.perform(
      .createList(name: "Reading", systemImage: "list.bullet"),
      sortedBy: .chronological
    )
    guard case .listCreated(let reading) = listUpdate.outcome else {
      return XCTFail("The test list was not created.")
    }
    let imports = ShareImportStore(sharedRootURL: root)

    let saved = try await imports.save(
      ShareImportRequest(content: "First", destinationListID: reading.id)
    )
    guard case .pending = saved else {
      return XCTFail("The extension must never write to the SwiftData store.")
    }
    let beforeImport = await library.snapshot(sortedBy: .chronological)
    XCTAssertTrue(beforeImport.snips.isEmpty)

    let imported = await imports.importPending(into: library)
    XCTAssertEqual(imported, ShareImportSummary(imported: 1, failed: 0))
    let afterImport = await library.snapshot(sortedBy: .chronological)
    XCTAssertEqual(afterImport.snips.first?.listID, reading.id)
  }

  func testPendingShareImportsItsAttachmentExactlyOnce() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = ShareImportStore.storeURL(in: root)
    let sourceURL = root.appendingPathComponent("shared-image.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceURL)
    let staging = try ShareImportStagingArea(sharedRootURL: root)
    let attachment = try staging.copyProviderFile(at: sourceURL, contentType: "public.png")
    let imports = ShareImportStore(sharedRootURL: root)
    let request = ShareImportRequest(
      content: "From Photos",
      destinationListID: SnipList.inboxID,
      attachments: [attachment],
      requestID: staging.requestID
    )

    let saveResult = try await imports.save(request)
    XCTAssertEqual(saveResult, .pending(requestID: request.requestID))
    try FileManager.default.removeItem(at: sourceURL)
    let pendingBeforeImport = await imports.pendingImportCount()
    XCTAssertEqual(pendingBeforeImport, 1)

    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let firstImport = await imports.importPending(into: library)
    XCTAssertEqual(firstImport, ShareImportSummary(imported: 1, failed: 0))
    let pendingAfterImport = await imports.pendingImportCount()
    XCTAssertEqual(pendingAfterImport, 0)
    let firstSnapshot = await library.snapshot(sortedBy: .chronological)
    let snip = try XCTUnwrap(firstSnapshot.snips.first)
    let storedURL = try XCTUnwrap(firstSnapshot.attachmentURLs[snip.attachments[0].id])
    XCTAssertEqual(try Data(contentsOf: storedURL), Data([0x89, 0x50, 0x4E, 0x47]))

    let emptyImport = await imports.importPending(into: library)
    XCTAssertEqual(emptyImport, ShareImportSummary(imported: 0, failed: 0))
    let finalSnapshot = await library.snapshot(sortedBy: .chronological)
    XCTAssertEqual(finalSnapshot.snips.count, 1)
  }

  func testCrashAfterStoreSaveReplaysWithoutCreatingAnotherSnip() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = ShareImportStore.storeURL(in: root)
    let staging = try ShareImportStagingArea(sharedRootURL: root)
    let request = ShareImportRequest(
      content: "Replay me",
      destinationListID: SnipList.inboxID,
      requestID: staging.requestID
    )
    let publisher = ShareImportStore(sharedRootURL: root)
    let published = try await publisher.save(request)
    XCTAssertEqual(published, .pending(requestID: request.requestID))

    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let interrupted = ShareImportStore(
      sharedRootURL: root,
      afterPendingSaveBeforeCleanup: { throw SimulatedCrash() }
    )
    let interruptedImport = await interrupted.importPending(into: library)
    XCTAssertEqual(
      interruptedImport,
      ShareImportSummary(imported: 1, failed: 0, cleanupFailures: 1)
    )
    let interruptedSnapshot = await library.snapshot(sortedBy: .chronological)
    XCTAssertEqual(interruptedSnapshot.snips.count, 1)
    let pendingAfterCrash = await interrupted.pendingImportCount()
    XCTAssertEqual(pendingAfterCrash, 1)

    let resumed = ShareImportStore(sharedRootURL: root)
    let resumedImport = await resumed.importPending(into: library)
    XCTAssertEqual(resumedImport, ShareImportSummary(imported: 0, failed: 0))
    let pendingAfterResume = await resumed.pendingImportCount()
    XCTAssertEqual(pendingAfterResume, 0)
    let resumedSnapshot = await library.snapshot(sortedBy: .chronological)
    XCTAssertEqual(resumedSnapshot.snips.count, 1)
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShareImportStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

private struct SimulatedCrash: Error {}
