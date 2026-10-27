import Observation
import ImageIO
import SnipSnapCore
import SnipSnapCloud
import SnipSnapPersistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SnipSnapiOS

@MainActor
final class IOSBackupModelTests: IOSModelTestCase {
    func testIOSBackupCreationRoundTripsListsSnipsAndAttachmentBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("receipt.txt")
        let bytes = Data("Keep these attachment bytes".utf8)
        try bytes.write(to: input)
        let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("Source/source.json"))
        let model = makeImportModel(library: source)
        await model.load()
        let createdList = await model.createList(name: "Receipts")
        XCTAssertTrue(createdList)
        let listID = try XCTUnwrap(model.lists.first(where: { $0.name == "Receipts" })?.id)
        let createdSnip = await model.createSnip(content: "Saved receipt", in: listID, attachmentURLs: [input])
        XCTAssertTrue(createdSnip)
        let snipID = try XCTUnwrap(model.snips.first?.id)
        let backupURL = root.appendingPathComponent("Backup", isDirectory: true)

        try await model.createBackup(at: backupURL)

        let target = try JSONSnipLibrary(fileURL: root.appendingPathComponent("Target/target.json"))
        let imported = makeImportModel(library: target)
        await imported.load()
        let createdExisting = await imported.createSnip(content: "Already here", in: SnipList.inboxID)
        XCTAssertTrue(createdExisting)
        try await imported.previewBackupImport(from: backupURL)
        try await imported.confirmBackupImport()
        XCTAssertEqual(Set(imported.snips.map(\.content)), ["Already here", "Saved receipt"])
        XCTAssertEqual(imported.lists.first(where: { $0.id == listID })?.name, "Receipts")
        let restored = try XCTUnwrap(imported.snips.first(where: { $0.id == snipID }))
        XCTAssertEqual(restored.listID, listID)
        let attachment = try XCTUnwrap(restored.attachments.first)
        let restoredURL = try XCTUnwrap(imported.attachmentURL(for: attachment.id))
        XCTAssertEqual(try Data(contentsOf: restoredURL), bytes)
    }

    func testIOSBackupCreationIncludesExternallyAddedLocalAttachmentsWithoutReloading() async throws {
        for cloudActivity: Bool? in [nil, false, true] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("IOSExternalBackupTests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("Source/source.json"))
            let model = IOSAppModel(
                library: source,
                cloudSyncHandler: cloudActivity.map { MutableIOSCloudSyncHandler(active: $0, states: [:]) }
            )
            await model.load()
            XCTAssertTrue(model.snips.isEmpty)
            let input = root.appendingPathComponent("shared-attachment.txt")
            let bytes = Data("Attachment committed by another app surface".utf8)
            try bytes.write(to: input)
            _ = try await source.perform(.add(
                content: "Added externally", origin: .quickEntry, source: nil, listID: SnipList.inboxID,
                attachmentURLs: [input], requestID: UUID(), now: Date()
            ), sortedBy: .chronological)
            XCTAssertTrue(model.snips.isEmpty)

            let backup = root.appendingPathComponent("Backup", isDirectory: true)
            try await model.createBackup(at: backup)

            let restored = try JSONSnipArchiveTransfer.read(from: backup)
            XCTAssertEqual(restored.snips.map(\.content), ["Added externally"])
            let attachmentID = try XCTUnwrap(restored.snips.first?.attachments.first?.id)
            let restoredURL = try XCTUnwrap(restored.attachmentURLs[attachmentID])
            XCTAssertEqual(try Data(contentsOf: restoredURL), bytes)
        }
    }

    func testIOSBackupCreationDownloadsAnExternallyCommittedAttachmentBeforeModelRefresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSFreshRemoteBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let downloaded = root.appendingPathComponent("remote-attachment.txt")
        let bytes = Data("Remote attachment committed after the screen loaded".utf8)
        try bytes.write(to: downloaded)
        let source = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("Source/store.sqlite"))
        let handler = IOSCopyShareActionHandlerProbe(states: [:], results: [.success(downloaded)])
        let model = IOSAppModel(library: source, cloudSyncHandler: handler)
        await model.load()
        XCTAssertTrue(model.snips.isEmpty)
        _ = try await source.perform(.add(
            content: "New remote metadata", origin: .quickEntry, source: nil, listID: SnipList.inboxID,
            attachmentURLs: [downloaded], requestID: UUID(), now: Date()
        ), sortedBy: .chronological)
        let archive = try await source.archive()
        let attachment = try XCTUnwrap(archive.snips.first?.attachments.first)
        let unavailableLocalURL = try XCTUnwrap(archive.attachmentURLs[attachment.id])
        try FileManager.default.removeItem(at: unavailableLocalURL)
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: unavailableLocalURL.path))
        XCTAssertTrue(model.snips.isEmpty)

        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        try await model.createBackup(at: backup)

        let restored = try JSONSnipArchiveTransfer.read(from: backup)
        let restoredURL = try XCTUnwrap(restored.attachmentURLs[attachment.id])
        XCTAssertEqual(try Data(contentsOf: restoredURL), bytes)
        let calls = await handler.prepareCalls()
        XCTAssertEqual(calls.map(\.id), [attachment.id])
        XCTAssertEqual(calls.map(\.use), [.export])
    }

    func testIOSBackupCreationDownloadsEvictedAttachmentsBeforeExport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSCloudBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let download = root.appendingPathComponent("download.txt")
        let bytes = Data("Downloaded for the backup".utf8)
        try bytes.write(to: download)
        let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("Source/source.json"))
        _ = try await source.perform(.add(
            content: "Synced snip", origin: .quickEntry, source: nil, listID: SnipList.inboxID,
            attachmentURLs: [download], requestID: UUID(), now: Date()
        ), sortedBy: .chronological)
        let snapshot = try await source.checkedSnapshot(sortedBy: .chronological)
        let attachment = try XCTUnwrap(snapshot.snips.first?.attachments.first)
        let evicted = try XCTUnwrap(snapshot.attachmentURLs[attachment.id])
        try FileManager.default.removeItem(at: evicted)
        let handler = IOSCopyShareActionHandlerProbe(
            states: [attachment.id: .waiting], results: [.success(download)]
        )
        let model = IOSAppModel(library: source, cloudSyncHandler: handler)
        await model.load()

        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        try await model.createBackup(at: backup)
        let restored = try JSONSnipArchiveTransfer.read(from: backup)
        let restoredURL = try XCTUnwrap(restored.attachmentURLs[attachment.id])
        XCTAssertEqual(try Data(contentsOf: restoredURL), bytes)
        let calls = await handler.prepareCalls()
        XCTAssertEqual(calls.map(\.use), [.export])
    }

    func testIOSBackupCreationFailsWhenAnAttachmentCannotDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSFailedBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("unavailable.txt")
        try Data("Required attachment".utf8).write(to: input)
        let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("Source/source.json"))
        _ = try await source.perform(.add(
            content: "Keep complete", origin: .quickEntry, source: nil, listID: SnipList.inboxID,
            attachmentURLs: [input], requestID: UUID(), now: Date()
        ), sortedBy: .chronological)
        let snapshot = try await source.checkedSnapshot(sortedBy: .chronological)
        let attachment = try XCTUnwrap(snapshot.snips.first?.attachments.first)
        let handler = IOSCopyShareActionHandlerProbe(
            states: [attachment.id: .waiting], results: [.failure(SnipLibraryError.attachmentCopyFailed)]
        )
        let model = IOSAppModel(library: source, cloudSyncHandler: handler)
        await model.load()

        do {
            try await model.createBackup(at: root.appendingPathComponent("Backup"))
            XCTFail("A backup must include every attachment.")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .attachmentCopyFailed)
        }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.snips.first?.content, "Keep complete")
    }

    func testDismissingSettingsRejectsADelayedBackupPreviewAndPreservesOtherErrors() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSImportLifetimeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backupURL = root.appendingPathComponent("Backup.json")
        let source = try JSONSnipLibrary(fileURL: backupURL)
        _ = try await source.perform(.add(
            content: "Late backup", origin: .quickEntry, source: nil, listID: SnipList.inboxID,
            attachmentURLs: [], requestID: UUID(), now: Date()
        ), sortedBy: .chronological)
        let target = try JSONSnipLibrary(fileURL: root.appendingPathComponent("Target.json"))
        let gate = DelayedIOSBackupPreviewGate()
        let actions = DirectSnipLibraryUserActions(library: target, previewBackupImport: { url, library in
            let preview = try await SnipLibraryImport.preview(backupURL: url, target: library)
            await gate.pause()
            return preview
        })
        let model = IOSAppModel(library: target, userActions: actions)
        await model.load()
        model.errorMessage = "Unrelated library error"
        let lifetime = IOSSettingsBackupLifetime()
        lifetime.begin()
        let previewTask = Task { try await model.previewBackupImport(from: backupURL) }
        lifetime.task = Task { _ = try? await previewTask.value }
        await gate.waitUntilPaused()

        lifetime.end(library: model)
        await gate.resume()
        do {
            try await previewTask.value
            XCTFail("A dismissed Settings screen must not retain a late preview.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(lifetime.isActive)
        XCTAssertNil(model.pendingImportPreview)
        XCTAssertEqual(model.errorMessage, "Unrelated library error")
        try await model.confirmBackupImport()
        XCTAssertTrue(model.snips.isEmpty)
        try await model.previewBackupImport(from: backupURL)
        XCTAssertEqual(model.pendingImportPreview?.addedSnipCount, 1)
        model.cancelBackupImport()
    }

    func testBackupPickerFailureRecordsTheLocalAlertAndIgnoresCancellation() {
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSAppModel(library: ModelTestLibrary(), diagnostics: diagnostics.recorder)
        model.errorMessage = "Unrelated library error"
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                            userInfo: [NSLocalizedDescriptionKey: "private backup path"])

        XCTAssertNil(model.backupImportSelectionFailed(CancellationError()))
        XCTAssertNil(model.backupImportSelectionFailed(CocoaError(.userCancelled)))
        XCTAssertTrue(diagnostics.events.isEmpty)
        XCTAssertEqual(model.backupImportSelectionFailed(error), "private backup path")
        XCTAssertEqual(model.errorMessage, "Unrelated library error")
        XCTAssertEqual(diagnostics.events, [
            .failure(operation: "backup.import_select", errorCode: "cocoa.257", visibility: .user)
        ])
        XCTAssertFalse(diagnostics.events.map(\.line).joined().contains("private backup path"))

        let unrelated = NSError(domain: "PrivateBackupDomain", code: NSUserCancelledError)
        XCTAssertNotNil(model.backupImportSelectionFailed(unrelated))
        XCTAssertEqual(diagnostics.events.last?.operation, "backup.import_select")
        XCTAssertEqual(diagnostics.events.last?.outcome, .failed)
        XCTAssertEqual(diagnostics.events.last?.errorCode, "other.UnknownError")
    }

    func testBackupPreviewFailureThrowsWithoutReplacingAnUnrelatedGlobalError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSImportErrorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try JSONSnipLibrary(fileURL: root.appendingPathComponent("Target.json"))
        let model = makeImportModel(library: target)
        await model.load()
        model.errorMessage = "Unrelated library error"

        do {
            try await model.previewBackupImport(from: root.appendingPathComponent("Missing.json"))
            XCTFail("An unavailable backup must report its error to the caller.")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertNil(model.pendingImportPreview)
        XCTAssertEqual(model.errorMessage, "Unrelated library error")
    }

    func testBackupConfirmationRejectsChangedLibraryAndKeepsItsErrorLocal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSImportChangedTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backupURL = root.appendingPathComponent("Backup.json")
        let source = try JSONSnipLibrary(fileURL: backupURL)
        _ = try await source.perform(.add(
            content: "From backup", origin: .quickEntry, source: nil, listID: SnipList.inboxID,
            attachmentURLs: [], requestID: UUID(), now: Date()
        ), sortedBy: .chronological)
        let target = try JSONSnipLibrary(fileURL: root.appendingPathComponent("Target.json"))
        let model = makeImportModel(library: target)
        await model.load()
        try await model.previewBackupImport(from: backupURL)
        let saved = await model.createSnip(content: "Changed after preview", in: SnipList.inboxID)
        XCTAssertTrue(saved)
        model.errorMessage = "Unrelated library error"

        do {
            try await model.confirmBackupImport()
            XCTFail("Import must preserve edits made after its preview.")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .importChanged)
        }
        XCTAssertNil(model.pendingImportPreview)
        XCTAssertEqual(model.snips.map(\.content), ["Changed after preview"])
        XCTAssertEqual(model.errorMessage, "Unrelated library error")
    }

    func testIOSBackupImportWaitsForConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backupURL = root.appendingPathComponent("Backup.json")
        let targetURL = root.appendingPathComponent("Target.json")
        let backup = try JSONSnipLibrary(fileURL: backupURL)
        let update = try await backup.perform(
            .add(
                content: "From backup",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        guard case .add(.added(let importedID)) = update.outcome else {
            return XCTFail("The backup must contain the added snip.")
        }
        let target = try JSONSnipLibrary(fileURL: targetURL)
        let model = makeImportModel(library: target)
        await model.load()

        try await model.previewBackupImport(from: backupURL)

        XCTAssertEqual(model.pendingImportPreview?.addedSnipCount, 1)
        XCTAssertTrue(model.snips.isEmpty)

        try await model.confirmBackupImport()

        XCTAssertEqual(model.snips.map(\.id), [importedID])
    }

    func testIOSBackupPickerAndModelImportAnAttachmentBackupFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSFolderImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputURL = root.appendingPathComponent("attachment.txt")
        let bytes = Data("folder attachment".utf8)
        try bytes.write(to: inputURL)
        let sourceURL = root.appendingPathComponent("Source/source.json")
        let source = try JSONSnipLibrary(fileURL: sourceURL)
        _ = try await source.perform(
            .add(
                content: "From folder backup",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [inputURL],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 100)
            ),
            sortedBy: .chronological
        )
        let backupFolder = root.appendingPathComponent("Backup", isDirectory: true)
        try JSONSnipArchiveTransfer.write(try await source.archive(), to: backupFolder)
        let targetURL = root.appendingPathComponent("Target/target.json")
        let target = try JSONSnipLibrary(fileURL: targetURL)
        let model = makeImportModel(library: target)
        await model.load()

        try await model.previewBackupImport(from: backupFolder)

        XCTAssertEqual(model.pendingImportPreview?.addedAttachmentCount, 1)
        XCTAssertTrue(model.snips.isEmpty)
        try await model.confirmBackupImport()
        let attachmentID = try XCTUnwrap(model.snips.first?.attachments.first?.id)
        let targetSnapshot = try await target.checkedSnapshot(sortedBy: .chronological)
        let savedURL = try XCTUnwrap(targetSnapshot.attachmentURLs[attachmentID])
        XCTAssertEqual(try Data(contentsOf: savedURL), bytes)
    }

    func testIOSBackupImportPreviewNamesAnAddedEmptyList() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSListImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backupURL = root.appendingPathComponent("Backup.json")
        let targetURL = root.appendingPathComponent("Target.json")
        let backup = try JSONSnipLibrary(fileURL: backupURL)
        _ = try await backup.perform(
            .createList(name: "Empty", systemImage: "tray"),
            sortedBy: .manual
        )
        let target = try JSONSnipLibrary(fileURL: targetURL)
        let model = makeImportModel(library: target)
        await model.load()

        try await model.previewBackupImport(from: backupURL)

        XCTAssertEqual(model.pendingImportPreview?.addedListCount, 1)
        XCTAssertEqual(model.pendingImportPreview?.localizedSummary, "0 snips, 1 new list")
    }
}

private actor DelayedIOSBackupPreviewGate {
    private var isPaused = false
    private var didResume = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        guard !didResume else { return }
        isPaused = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        didResume = true
        continuation?.resume()
        continuation = nil
    }
}
