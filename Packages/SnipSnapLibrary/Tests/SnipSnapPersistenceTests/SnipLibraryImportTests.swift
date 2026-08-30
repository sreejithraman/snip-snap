import CryptoKit
import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapPersistence

final class SnipLibraryImportTests: XCTestCase {
  func testBackupPreviewKeepsOneRootDescriptorAcrossAWholeDirectorySwap() throws {
    let original = Data("inside".utf8)
    let outside = Data("secret".utf8)
    XCTAssertEqual(original.count, outside.count)
    let relativePath = "Nested/file.txt"
    let fixture = try makeBackupFixture(
      relativePath: relativePath,
      attachmentBytes: original
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let outsideBackup = fixture.root.appendingPathComponent("OutsideBackup", isDirectory: true)
    let outsideAttachment = outsideBackup.appendingPathComponent("Attachments")
      .appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: outsideAttachment.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try outside.write(to: outsideAttachment)
    let parkedBackup = fixture.root.appendingPathComponent("ParkedBackup", isDirectory: true)

    let staged = try JSONSnipArchiveTransfer.stageForImport(
      from: fixture.backupURL,
      transitionID: UUID(),
      afterManifestRead: {
        try FileManager.default.moveItem(at: fixture.backupURL, to: parkedBackup)
        try FileManager.default.createSymbolicLink(
          at: fixture.backupURL,
          withDestinationURL: outsideBackup
        )
      }
    )
    defer { try? staged.lease.release() }

    let attachmentID = try XCTUnwrap(staged.archive.snips.first?.attachments.first?.id)
    let stagedURL = try XCTUnwrap(staged.archive.attachmentURLs[attachmentID])
    XCTAssertEqual(try Data(contentsOf: stagedURL), original)
  }

  func testStagingLeaseRetriesCleanupAfterOneFailure() throws {
    let root = temporaryDirectory()
    let probe = FailOnceStagingCleanup(rootURL: root)
    let lease = SnipImportStagingLease(rootURL: root) {
      try probe.cleanup()
    }

    XCTAssertThrowsError(try lease.release())
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

    try lease.release()

    XCTAssertEqual(probe.attemptCount, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testBackupPreviewRejectsDocumentSymlinkOutsideSelectedBackup() async throws {
    let fixture = try makeBackupFixture(relativePath: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let outsideDocument = fixture.root.appendingPathComponent("outside.json")
    try FileManager.default.copyItem(at: fixture.documentURL, to: outsideDocument)
    try FileManager.default.removeItem(at: fixture.documentURL)
    try FileManager.default.createSymbolicLink(
      at: fixture.documentURL,
      withDestinationURL: outsideDocument
    )
    let target = try SwiftDataSnipLibrary(
      storeURL: fixture.root.appendingPathComponent("target.store")
    )

    await assertPreviewRejects(fixture.backupURL, target: target)
    let syncSnapshot = try await target.transferSnapshot(revision: 0)
    XCTAssertTrue(syncSnapshot.snips.isEmpty)
    XCTAssertTrue(syncSnapshot.attachmentData.isEmpty)
  }

  func testRootedDescriptorCopyIgnoresIntermediatePathSwapToOutside() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let attachmentRoot = root.appendingPathComponent("Attachments", isDirectory: true)
    let nested = attachmentRoot.appendingPathComponent("Nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let safeBytes = Data("inside".utf8)
    try safeBytes.write(to: nested.appendingPathComponent("file.txt"))
    let outside = root.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try Data("secret".utf8).write(to: outside.appendingPathComponent("file.txt"))
    let parked = attachmentRoot.appendingPathComponent("Parked", isDirectory: true)
    let destination = root.appendingPathComponent("staged.txt")

    let copied = try AttachmentFileIO.copyRegularFile(
      fromRoot: attachmentRoot,
      relativePath: "Nested/file.txt",
      to: destination,
      expectedByteCount: Int64(safeBytes.count),
      beforeFinalOpen: {
        try FileManager.default.moveItem(at: nested, to: parked)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)
      }
    )

    XCTAssertEqual(try Data(contentsOf: destination), safeBytes)
    XCTAssertEqual(copied.digest, Data(SHA256.hash(data: safeBytes)))
  }

  func testBackupPreviewRejectsAbsoluteAttachmentPathWithoutReadingOutsideBytes() async throws {
    let fixture = try makeBackupFixture(relativePath: "/private/outside.txt")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let outside = fixture.root.appendingPathComponent("outside.txt")
    try Data("outside secret".utf8).write(to: outside)
    let target = try SwiftDataSnipLibrary(
      storeURL: fixture.root.appendingPathComponent("target.store")
    )

    await assertPreviewRejects(fixture.documentURL, target: target)
    let snapshot = await target.snapshot(sortedBy: .chronological)
    XCTAssertTrue(snapshot.snips.isEmpty)
  }

  func testBackupPreviewRejectsParentTraversalWithoutReadingOutsideBytes() async throws {
    let fixture = try makeBackupFixture(relativePath: "../outside.txt")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("outside secret".utf8).write(
      to: fixture.backupURL.appendingPathComponent("outside.txt")
    )
    let target = try SwiftDataSnipLibrary(
      storeURL: fixture.root.appendingPathComponent("target.store")
    )

    await assertPreviewRejects(fixture.documentURL, target: target)
    let snapshot = await target.snapshot(sortedBy: .chronological)
    XCTAssertTrue(snapshot.snips.isEmpty)
  }

  func testBackupPreviewRejectsAttachmentSymlinkOutsideSelectedBackup() async throws {
    let fixture = try makeBackupFixture(relativePath: "Alias/outside.txt")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try Data("outside secret".utf8).write(to: outside.appendingPathComponent("outside.txt"))
    try FileManager.default.createSymbolicLink(
      at: fixture.backupURL.appendingPathComponent("Attachments/Alias"),
      withDestinationURL: outside
    )
    let target = try SwiftDataSnipLibrary(
      storeURL: fixture.root.appendingPathComponent("target.store")
    )

    await assertPreviewRejects(fixture.documentURL, target: target)
    let snapshot = await target.snapshot(sortedBy: .chronological)
    XCTAssertTrue(snapshot.snips.isEmpty)
  }

  func testBackupPreviewRejectsMissingAttachment() async throws {
    let fixture = try makeBackupFixture(relativePath: "Missing/file.txt")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = try SwiftDataSnipLibrary(
      storeURL: fixture.root.appendingPathComponent("target.store")
    )

    await assertPreviewRejects(fixture.documentURL, target: target)
    let snapshot = await target.snapshot(sortedBy: .chronological)
    XCTAssertTrue(snapshot.snips.isEmpty)
  }

  func testBackupPreviewAcceptsAValidNestedAttachment() async throws {
    let bytes = Data("nested attachment".utf8)
    let fixture = try makeBackupFixture(
      relativePath: "Nested/Folder/file.txt",
      attachmentBytes: bytes
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = try SwiftDataSnipLibrary(
      storeURL: fixture.root.appendingPathComponent("target.store")
    )

    let preview = try await SnipLibraryImport.preview(
      backupURL: fixture.documentURL,
      target: target
    )
    let result = try await SnipLibraryImport.apply(preview, to: target)

    let attachmentID = try XCTUnwrap(result.snapshot.snips.first?.attachments.first?.id)
    let targetURL = try XCTUnwrap(result.snapshot.attachmentURLs[attachmentID])
    XCTAssertEqual(try Data(contentsOf: targetURL), bytes)
  }

  func testJSONApplyRejectsStagedBytesThatNoLongerMatchPreviewDigest() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = try JSONSnipLibrary(fileURL: root.appendingPathComponent("target.json"))
    try await assertChangedStageIsRejected(target: target, root: root)
  }

  func testSwiftDataApplyRejectsStagedBytesThatNoLongerMatchPreviewDigest() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("target.store"))
    try await assertChangedStageIsRejected(target: target, root: root)
  }

  func testLibraryPreviewStagesSourceBeforeLaterMutation() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inputURL = root.appendingPathComponent("input.txt")
    let original = Data("original".utf8)
    let changed = Data("modified".utf8)
    XCTAssertEqual(original.count, changed.count)
    try original.write(to: inputURL)
    let source = try JSONSnipLibrary(
      fileURL: root.appendingPathComponent("Source/source.json")
    )
    _ = try await source.perform(
      .add(
        content: "With attachment",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [inputURL],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 100)
      ),
      sortedBy: .chronological
    )
    let target = try JSONSnipLibrary(
      fileURL: root.appendingPathComponent("Target/target.json")
    )
    let preview = try await SnipLibraryImport.preview(source: source, target: target)
    let sourceSnapshot = try await source.checkedSnapshot(sortedBy: .chronological)
    let sourceAttachmentURL = try XCTUnwrap(sourceSnapshot.attachmentURLs.values.first)
    try changed.write(to: sourceAttachmentURL, options: .atomic)

    let result = try await SnipLibraryImport.apply(preview, to: target)

    let attachmentID = try XCTUnwrap(result.snapshot.snips.first?.attachments.first?.id)
    let targetSnapshot = try await target.transferSnapshot(revision: 0)
    XCTAssertEqual(targetSnapshot.attachmentData[attachmentID], original)
  }

  func testBackupPreviewStagesSparseAttachmentWithoutMaterializingDataAndCancelCleansIt() async throws {
    let byteCount: Int64 = 128 * 1024 * 1024
    let relativePath = "Large/sparse.bin"
    let fixture = try makeBackupFixture(
      relativePath: relativePath,
      attachmentByteCount: byteCount
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let sourceURL = fixture.backupURL.appendingPathComponent("Attachments")
      .appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: sourceURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    XCTAssertTrue(FileManager.default.createFile(atPath: sourceURL.path, contents: nil))
    let handle = try FileHandle(forWritingTo: sourceURL)
    try handle.truncate(atOffset: UInt64(byteCount))
    try handle.close()
    let target = try SwiftDataSnipLibrary(
      storeURL: fixture.root.appendingPathComponent("target.store")
    )

    var preview: SnipImportPreview? = try await SnipLibraryImport.preview(
      backupURL: fixture.documentURL,
      target: target
    )
    let stagingRoot = try XCTUnwrap(preview?.stagingRootURL)
    let stagedURL = try XCTUnwrap(preview?.stagedAttachmentURLs.values.first)
    let values = try stagedURL.resourceValues(forKeys: [
      .fileSizeKey, .totalFileAllocatedSizeKey,
    ])
    XCTAssertEqual(Int64(values.fileSize ?? -1), byteCount)
    XCTAssertLessThan(values.totalFileAllocatedSize ?? Int.max, 4 * 1024 * 1024)
    XCTAssertTrue(preview?.source.attachmentData.isEmpty == true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: stagingRoot.path))

    preview = nil

    XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
  }

  func testSwiftDataTargetPreviewKeepsLargeAttachmentURLBackedThroughPlanning() async throws {
    let byteCount: UInt64 = 128 * 1024 * 1024
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sparseURL = root.appendingPathComponent("target-sparse.bin")
    XCTAssertTrue(FileManager.default.createFile(atPath: sparseURL.path, contents: nil))
    let handle = try FileHandle(forWritingTo: sparseURL)
    try handle.truncate(atOffset: byteCount)
    try handle.close()
    let target = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("target.store"))
    _ = try await target.perform(
      .add(
        content: "Existing large attachment",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [sparseURL],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 100)
      ),
      sortedBy: .chronological
    )
    let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("empty.json"))

    let targetPreview = try await target.previewTransferSnapshot(revision: 0)
    XCTAssertTrue(targetPreview.attachmentData.isEmpty)
    XCTAssertEqual(targetPreview.attachmentFileURLs.count, 1)
    let preview = try await SnipLibraryImport.preview(source: source, target: target)

    XCTAssertEqual(preview.addedSnipCount, 0)
    XCTAssertEqual(preview.addedAttachmentCount, 0)
    XCTAssertTrue(preview.source.attachmentData.isEmpty)
  }

  func testConfirmedImportUsesImmutableStageAfterSourceMutationAndCleansIt() async throws {
    let original = Data("original source".utf8)
    let changed = Data("changed source!".utf8)
    XCTAssertEqual(original.count, changed.count)
    let relativePath = "Nested/file.txt"
    let fixture = try makeBackupFixture(
      relativePath: relativePath,
      attachmentBytes: original
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = try SwiftDataSnipLibrary(
      storeURL: fixture.root.appendingPathComponent("target.store")
    )
    let preview = try await SnipLibraryImport.preview(
      backupURL: fixture.documentURL,
      target: target
    )
    let stagingRoot = try XCTUnwrap(preview.stagingRootURL)
    try changed.write(
      to: fixture.backupURL.appendingPathComponent("Attachments")
        .appendingPathComponent(relativePath),
      options: .atomic
    )

    let result = try await SnipLibraryImport.apply(preview, to: target)

    let attachmentID = try XCTUnwrap(result.snapshot.snips.first?.attachments.first?.id)
    let importedURL = try XCTUnwrap(result.snapshot.attachmentURLs[attachmentID])
    XCTAssertEqual(try Data(contentsOf: importedURL), original)
    let syncSnapshot = try await target.transferSnapshot(revision: 0)
    XCTAssertEqual(syncSnapshot.attachmentData[attachmentID], original)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
  }

  func testFailedConfirmedImportCleansItsImmutableStage() async throws {
    let fixture = try makeBackupFixture(
      relativePath: "Nested/file.txt",
      attachmentBytes: Data("staged".utf8)
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = try SwiftDataSnipLibrary(
      storeURL: fixture.root.appendingPathComponent("target.store")
    )
    let preview = try await SnipLibraryImport.preview(
      backupURL: fixture.documentURL,
      target: target
    )
    let stagingRoot = try XCTUnwrap(preview.stagingRootURL)
    _ = try await target.perform(
      .restore(snips: [snip(content: "Arrived later")]),
      sortedBy: .chronological
    )

    do {
      _ = try await SnipLibraryImport.apply(preview, to: target)
      XCTFail("Expected a changed target to reject the import")
    } catch SnipLibraryError.importChanged {
    }

    XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
  }

  func testLegacyBackupPreviewLeavesSourceBytesAndModificationDateUnchanged() async throws {
    let fixture = try makeBackupFixture(
      version: JSONSnipLibrary.legacyVersion,
      relativePath: nil,
      usesLegacyKeys: true
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let documentURL = fixture.documentURL
    let knownDate = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes([.modificationDate: knownDate], ofItemAtPath: documentURL.path)
    let beforeBytes = try Data(contentsOf: documentURL)
    let beforeDate = try documentURL.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    let target = try SwiftDataSnipLibrary(
      storeURL: fixture.root.appendingPathComponent("target.store")
    )

    _ = try await SnipLibraryImport.preview(backupURL: fixture.documentURL, target: target)

    XCTAssertEqual(try Data(contentsOf: documentURL), beforeBytes)
    XCTAssertEqual(
      try documentURL.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate,
      beforeDate
    )
  }

  func testCommitRejectsSameIDSnipThatArrivesAfterValidation() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("target.store")
    let remoteLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
    let sharedID = UUID()
    let remote = snip(id: sharedID, content: "Remote")
    let target = try SwiftDataSnipLibrary(
      storeURL: storeURL,
      beforeImportCommit: {
        _ = try await remoteLibrary.perform(.restore(snips: [remote]), sortedBy: .manual)
      }
    )
    let source = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("source.json"))
    _ = try await source.perform(
      .restore(snips: [snip(id: sharedID, content: "Backup")]),
      sortedBy: .manual
    )
    let preview = try await SnipLibraryImport.preview(source: source, target: target)
    let actions = SnipLibraryDeviceActions(
      library: target,
      journalURL: directory.appendingPathComponent("device-actions.json")
    )

    do {
      _ = try await actions.applyImport(preview, sortedBy: .manual)
      XCTFail("Expected a changed target to reject the import")
    } catch SnipLibraryError.importChanged {
    }

    let current = try await target.checkedSnapshot(sortedBy: .manual)
    let history = try await actions.state(sortedBy: .manual)
    XCTAssertEqual(current.snips.map(\.content), ["Remote"])
    XCTAssertFalse(history.canUndo)
  }

  func testCommitRejectsSameIDListThatArrivesAfterValidation() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("target.store")
    let remoteLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
    let sharedID = UUID()
    let remoteList = SnipList(
      id: sharedID,
      name: "Remote",
      systemImage: "tray",
      position: 1
    )
    let target = try SwiftDataSnipLibrary(
      storeURL: storeURL,
      beforeImportCommit: {
        _ = try await remoteLibrary.mergeTransferSnapshot(
          SnipLibraryTransferSnapshot(
            revision: 0,
            snips: [],
            lists: [.inbox, remoteList],
            attachmentData: [:]
          ),
          transitionID: UUID()
        )
      }
    )
    let source = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("source.json"))
    let backupList = SnipList(
      id: sharedID,
      name: "Backup",
      systemImage: "archivebox",
      position: 1
    )
    _ = try await source.mergeTransferSnapshot(
      SnipLibraryTransferSnapshot(
        revision: 0,
        snips: [snip(content: "Filed", listID: sharedID)],
        lists: [.inbox, backupList],
        attachmentData: [:]
      ),
      transitionID: UUID()
    )
    let preview = try await SnipLibraryImport.preview(source: source, target: target)
    let actions = SnipLibraryDeviceActions(
      library: target,
      journalURL: directory.appendingPathComponent("device-actions.json")
    )

    do {
      _ = try await actions.applyImport(preview, sortedBy: .manual)
      XCTFail("Expected a changed target to reject the import")
    } catch SnipLibraryError.importChanged {
    }

    let current = try await target.checkedSnapshot(sortedBy: .manual)
    let history = try await actions.state(sortedBy: .manual)
    XCTAssertEqual(current.lists.first { $0.id == sharedID }?.name, "Remote")
    XCTAssertTrue(current.snips.isEmpty)
    XCTAssertFalse(history.canUndo)
  }

  func testRenamedListInBackupKeepsCurrentFieldsAndImportsItsSnips() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("target.store"))
    let listID = UUID()
    let currentList = SnipList(
      id: listID,
      name: "Current name",
      systemImage: "tray",
      position: 1
    )
    let backupList = SnipList(
      id: listID,
      name: "Backup name",
      systemImage: "archivebox",
      position: 1
    )
    let transitionID = UUID()
    _ = try await target.mergeTransferSnapshot(
      transferSnapshot(lists: [.inbox, currentList]),
      transitionID: transitionID
    )
    let sourceSnip = snip(content: "Filed in backup", listID: listID)
    let source = transferSnapshot(
      snips: [sourceSnip],
      lists: [.inbox, backupList]
    )

    let preview = try await target.previewImport(source, transitionID: UUID())

    XCTAssertEqual(preview.addedListCount, 0)
    XCTAssertEqual(preview.addedSnipCount, 1)
    let result = try await target.applyImport(preview)
    XCTAssertEqual(result.snapshot.lists.first { $0.id == listID }?.desiredName, "Current name")
    XCTAssertEqual(result.snapshot.lists.first { $0.id == listID }?.systemImage, "tray")
    XCTAssertEqual(result.snapshot.snips.first { $0.id == sourceSnip.id }?.listID, listID)
  }

  func testPreviewDoesNotWriteAndConfirmedApplyMergesStableIdentities() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("source.json"))
    let target = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("target.store"))
    let sharedID = UUID()

    _ = try await target.perform(
      .restore(snips: [snip(id: sharedID, content: "Current")]),
      sortedBy: .chronological
    )
    _ = try await source.perform(
      .restore(snips: [
        snip(id: sharedID, content: "Backup edit"),
        snip(content: "Backup only"),
      ]),
      sortedBy: .chronological
    )

    let preview = try await SnipLibraryImport.preview(source: source, target: target)

    XCTAssertEqual(preview.addedSnipCount, 1)
    XCTAssertEqual(preview.recoveredSnipCount, 1)
    XCTAssertEqual(preview.totalSnipCount, 2)
    let beforeApply = await target.snapshot(sortedBy: .chronological)
    XCTAssertEqual(beforeApply.snips.map(\.content), ["Current"])

    let result = try await SnipLibraryImport.apply(preview, to: target)

    XCTAssertEqual(result.addedSnipCount, 1)
    XCTAssertEqual(result.recoveredSnipCount, 1)
    let contents = Set(result.snapshot.snips.map(\.content))
    XCTAssertEqual(contents, ["Current", "Backup edit", "Backup only"])
    XCTAssertEqual(result.snapshot.snips.first { $0.id == sharedID }?.content, "Current")
  }

  func testApplyRejectsAChangedTargetAndLeavesBothChangesIntact() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("source.json"))
    let target = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("target.store"))
    _ = try await source.perform(
      .restore(snips: [snip(content: "From backup")]),
      sortedBy: .chronological
    )
    let preview = try await SnipLibraryImport.preview(source: source, target: target)
    _ = try await target.perform(
      .restore(snips: [snip(content: "Arrived later")]),
      sortedBy: .chronological
    )

    do {
      _ = try await SnipLibraryImport.apply(preview, to: target)
      XCTFail("Expected a stale preview to fail")
    } catch SnipLibraryError.importChanged {
    }

    let current = await target.snapshot(sortedBy: .chronological)
    XCTAssertEqual(current.snips.map(\.content), ["Arrived later"])
  }

  func testConfirmedImportEntersDurableUndoHistory() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("target.store")
    let journalURL = directory.appendingPathComponent("device-actions.json")
    let source = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("source.json"))
    let target = try SwiftDataSnipLibrary(storeURL: storeURL)
    _ = try await source.perform(
      .restore(snips: [snip(content: "From backup")]),
      sortedBy: .chronological
    )
    let preview = try await SnipLibraryImport.preview(source: source, target: target)
    let actions = SnipLibraryDeviceActions(library: target, journalURL: journalURL)

    let imported = try await actions.applyImport(preview, sortedBy: .chronological)
    XCTAssertEqual(imported.snapshot.snips.map(\.content), ["From backup"])

    let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)
    let reopenedActions = SnipLibraryDeviceActions(library: reopened, journalURL: journalURL)
    let undone = try await reopenedActions.undo(sortedBy: .chronological)
    XCTAssertEqual(undone?.snapshot.snips, [])
  }

  func testConfirmedImportReturnsTheRequestedManualOrder() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("target.store"))
    let source = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("source.json"))
    let first = Snip(
      createdAt: Date(timeIntervalSince1970: 100),
      content: "First",
      origin: .quickEntry,
      manualPosition: -1
    )
    let second = Snip(
      createdAt: Date(timeIntervalSince1970: 300),
      content: "Second",
      origin: .quickEntry,
      manualPosition: 1
    )
    _ = try await target.perform(.restore(snips: [first, second]), sortedBy: .manual)
    _ = try await source.perform(
      .restore(snips: [Snip(
        createdAt: Date(timeIntervalSince1970: 200),
        content: "Imported",
        origin: .quickEntry,
        manualPosition: 0
      )]),
      sortedBy: .manual
    )
    let preview = try await SnipLibraryImport.preview(source: source, target: target)
    let actions = SnipLibraryDeviceActions(
      library: target,
      journalURL: directory.appendingPathComponent("device-actions.json")
    )

    let result = try await actions.applyImport(preview, sortedBy: .manual)

    let expected = try await target.checkedSnapshot(sortedBy: .manual)
    let chronological = try await target.checkedSnapshot(sortedBy: .chronological)
    XCTAssertEqual(result.snapshot, expected)
    XCTAssertNotEqual(result.snapshot.snips.map(\.id), chronological.snips.map(\.id))
  }

  func testModeManagedLibraryImportsThroughItsReservedWritePath() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("source.json"))
    _ = try await source.perform(
      .restore(snips: [snip(content: "Managed import")]),
      sortedBy: .chronological
    )
    let persistence = try SwiftDataSyncModePersistence(
      rootURL: directory.appendingPathComponent("SyncMode", isDirectory: true)
    )
    let target = try await persistence.activeLibrary()

    let preview = try await SnipLibraryImport.preview(source: source, target: target)
    let result = try await SnipLibraryImport.apply(preview, to: target)

    XCTAssertEqual(result.snapshot.snips.map(\.content), ["Managed import"])
    let reopened = try SwiftDataSyncModePersistence(
      rootURL: directory.appendingPathComponent("SyncMode", isDirectory: true)
    )
    let reopenedSnapshot = await (try await reopened.activeLibrary())
      .snapshot(sortedBy: .chronological)
    XCTAssertEqual(reopenedSnapshot.snips.map(\.content), ["Managed import"])
  }

  private func snip(
    id: UUID = UUID(),
    content: String,
    listID: UUID = SnipList.inboxID,
    updatedAt: TimeInterval = 100
  ) -> Snip {
    Snip(
      id: id,
      requestID: UUID(),
      createdAt: Date(timeIntervalSince1970: 50),
      updatedAt: Date(timeIntervalSince1970: updatedAt),
      content: content,
      origin: .quickEntry,
      listID: listID
    )
  }

  private func transferSnapshot(
    snips: [Snip] = [],
    lists: [SnipList]
  ) -> SnipLibraryTransferSnapshot {
    SnipLibraryTransferSnapshot(
      revision: 0,
      snips: snips,
      lists: lists,
      attachmentData: [:]
    )
  }

  private struct BackupFixture {
    let root: URL
    let backupURL: URL
    let documentURL: URL
  }

  private struct BackupDocument: Encodable {
    let version: Int
    let snips: [Snip]
    let lists: [SnipList]
    let seenRequestIDs: [UUID]
  }

  private struct LegacyBackupDocument: Encodable {
    let version: Int
    let items: [Snip]
    let sections: [SnipList]
    let seenRequestIDs: [UUID]
  }

  private func makeBackupFixture(
    version: Int = JSONSnipLibrary.currentVersion,
    relativePath: String?,
    attachmentBytes: Data? = nil,
    attachmentByteCount: Int64? = nil,
    usesLegacyKeys: Bool = false
  ) throws -> BackupFixture {
    let root = temporaryDirectory()
    let backupURL = root.appendingPathComponent("Backup", isDirectory: true)
    try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: false)
    let requestID = UUID()
    let attachments: [SnipAttachment]
    if let relativePath {
      let byteCount = attachmentByteCount
        ?? Int64(attachmentBytes?.count ?? Data("outside secret".utf8).count)
      attachments = [SnipAttachment(
        id: UUID(),
        fileName: URL(fileURLWithPath: relativePath).lastPathComponent,
        relativePath: relativePath,
        contentType: "public.plain-text",
        byteCount: byteCount
      )]
      if let attachmentBytes {
        let attachmentURL = backupURL.appendingPathComponent("Attachments", isDirectory: true)
          .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
          at: attachmentURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try attachmentBytes.write(to: attachmentURL)
      } else {
        try FileManager.default.createDirectory(
          at: backupURL.appendingPathComponent("Attachments", isDirectory: true),
          withIntermediateDirectories: true
        )
      }
    } else {
      attachments = []
    }
    let imported = Snip(
      requestID: requestID,
      createdAt: Date(timeIntervalSince1970: 100),
      updatedAt: Date(timeIntervalSince1970: 100),
      content: "Imported",
      origin: .quickEntry,
      attachments: attachments
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let document: Data
    if usesLegacyKeys {
      document = try encoder.encode(LegacyBackupDocument(
        version: version,
        items: [imported],
        sections: [.inbox],
        seenRequestIDs: [requestID]
      ))
    } else {
      document = try encoder.encode(BackupDocument(
        version: version,
        snips: [imported],
        lists: [.inbox],
        seenRequestIDs: [requestID]
      ))
    }
    let documentURL = backupURL.appendingPathComponent("snips.json")
    try document.write(to: documentURL)
    return BackupFixture(root: root, backupURL: backupURL, documentURL: documentURL)
  }

  private func assertPreviewRejects(
    _ backupURL: URL,
    target: any SnipLibrary,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await SnipLibraryImport.preview(backupURL: backupURL, target: target)
      XCTFail("Expected unsafe backup preview to fail", file: file, line: line)
    } catch {
      XCTAssertTrue(
        error is SnipLibraryError,
        "Expected a SnipLibraryError, got \(error)",
        file: file,
        line: line
      )
    }
  }

  private func assertChangedStageIsRejected(
    target: any SnipLibrary,
    root: URL
  ) async throws {
    let original = Data("original".utf8)
    let changed = Data("modified".utf8)
    XCTAssertEqual(original.count, changed.count)
    let fixture = try makeBackupFixture(
      relativePath: "Nested/file.txt",
      attachmentBytes: original
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let preview = try await SnipLibraryImport.preview(
      backupURL: fixture.documentURL,
      target: target
    )
    let stagingRoot = try XCTUnwrap(preview.stagingRootURL)
    let stagedURL = try XCTUnwrap(preview.stagedAttachmentURLs.values.first)
    try changed.write(to: stagedURL, options: .atomic)

    do {
      _ = try await SnipLibraryImport.apply(preview, to: target)
      XCTFail("Expected changed staged bytes to reject the import")
    } catch SnipLibraryError.importChanged {
    }

    let syncSnapshot = try await target.transferSnapshot(revision: 0)
    XCTAssertTrue(syncSnapshot.snips.isEmpty)
    XCTAssertTrue(syncSnapshot.attachmentData.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnipLibraryImportTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private final class FailOnceStagingCleanup: @unchecked Sendable {
  private let rootURL: URL
  private let lock = NSLock()
  private var attempts = 0

  init(rootURL: URL) {
    self.rootURL = rootURL
  }

  var attemptCount: Int {
    lock.withLock { attempts }
  }

  func cleanup() throws {
    let shouldFail = lock.withLock {
      attempts += 1
      return attempts == 1
    }
    if shouldFail { throw CocoaError(.fileWriteUnknown) }
    try FileManager.default.removeItem(at: rootURL)
  }
}
