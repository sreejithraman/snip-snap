import Foundation
import SnipSnapCore
import XCTest
@testable import SnipSnap
@testable import SnipSnapPersistence

final class AppModelCLIDataTests: StoreBackedTestCase {
    @MainActor
    func testDraftSaveReplacesAttachmentOrderAndCleansOnlyOmittedTemporaryFiles() async throws {
        let store = try storeURL()
        let model = AppModel(library: try JSONSnipLibrary(fileURL: store), defaults: defaults())
        await model.reload()
        let directory = store.deletingLastPathComponent()
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        let omitted = directory.appendingPathComponent("omitted.txt")
        let external = directory.appendingPathComponent("external.txt")
        let added = directory.appendingPathComponent("added.txt")
        let bytes = Data("Draft attachment bytes".utf8)
        for url in [first, second, omitted, external, added] {
            try bytes.write(to: url)
        }
        model.saveComposerText("Original", for: SnipList.inboxID)
        for url in [first, second, omitted] {
            model.addTemporaryDraftAttachment(url, to: SnipList.inboxID)
        }
        model.addDraftAttachments([external], to: SnipList.inboxID)
        let read = try await model.handleCLIRequest(request(.showDraft(list: "Inbox"), model))
        let revision = try XCTUnwrap(data(read).drafts?.first?.revision)

        let saved = try await model.handleCLIRequest(request(.saveDraft(list: "Inbox", text: "Replacement",
            attachmentPaths: [second.path, added.path, first.path], expectedRevision: revision), model))

        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID),
            ComposerDraft(text: "Replacement", attachments: [second, added, first]))
        XCTAssertEqual(try data(saved).drafts?.first?.attachmentPaths, [second.path, added.path, first.path])
        XCTAssertNotEqual(try data(saved).drafts?.first?.revision, revision)
        for url in [first, second, external, added] {
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: omitted.path))

        do {
            _ = try await model.handleCLIRequest(request(.saveDraft(list: "Inbox", text: "Stale",
                attachmentPaths: [added.path], expectedRevision: revision), model))
            XCTFail("A stale replacement must preserve the current draft and its temporary files")
        } catch SnipLibraryError.snipChanged {}
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID),
            ComposerDraft(text: "Replacement", attachments: [second, added, first]))
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(try Data(contentsOf: second), bytes)
    }

    @MainActor
    func testDraftSaveRejectsAStaleRevisionAndPreservesNewerText() async throws {
        let model = AppModel(library: try JSONSnipLibrary(fileURL: storeURL()), defaults: defaults())
        await model.reload()
        let read = try await model.handleCLIRequest(request(.showDraft(list: "Inbox"), model))
        let revision = try XCTUnwrap(data(read).drafts?.first?.revision)
        model.saveComposerText("Newer UI text", for: SnipList.inboxID)
        do {
            _ = try await model.handleCLIRequest(request(.saveDraft(list: "Inbox", text: "Old CLI text",
                attachmentPaths: [], expectedRevision: revision), model))
            XCTFail("Stale requests must preserve the UI draft")
        } catch SnipLibraryError.snipChanged {}
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "Newer UI text")
    }

    @MainActor
    func testBackupPreviewAndImportRoundTripAttachmentBytes() async throws {
        let sourceURL = try storeURL()
        let sourceLibrary = try JSONSnipLibrary(fileURL: sourceURL)
        let source = AppModel(library: sourceLibrary, defaults: defaults())
        let attachmentURL = sourceURL.deletingLastPathComponent().appendingPathComponent("evidence.txt")
        let bytes = Data("Backup attachment bytes".utf8)
        try bytes.write(to: attachmentURL)
        _ = try await sourceLibrary.perform(.add(content: "With attachment", origin: .quickEntry,
            source: nil, listID: SnipList.inboxID, attachmentURLs: [attachmentURL], requestID: UUID(),
            now: Date()), sortedBy: .chronological)
        await source.reload()
        let backup = sourceURL.deletingLastPathComponent().appendingPathComponent("Backup")
        _ = try await source.handleCLIRequest(request(.exportBackup(path: backup.path), source))

        let targetLibrary = try JSONSnipLibrary(fileURL: storeURL())
        let target = AppModel(library: targetLibrary, defaults: defaults(), userActionsFactory: { library in
            DirectSnipLibraryUserActions(library: library, previewBackupImport: { url, target in
                try await SnipLibraryImport.preview(backupURL: url, target: target)
            })
        })
        let preview = try await target.handleCLIRequest(request(.previewBackup(path: backup.path), target))
        let summary = try XCTUnwrap(data(preview).importPreview)
        XCTAssertNil(target.pendingImportPreview, "CLI preview must not open an app confirmation dialog")
        XCTAssertEqual(summary.addedSnipCount, 1)
        XCTAssertEqual(summary.addedAttachmentCount, 1)
        let imported = try await target.handleCLIRequest(request(.importBackup(previewID: summary.id), target))
        XCTAssertEqual(try data(imported).addedSnipCount, 1)
        let archive = try await targetLibrary.archive()
        XCTAssertEqual(archive.snips.map(\.content), ["With attachment"])
        let attachment = try XCTUnwrap(archive.snips.first?.attachments.first)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archive.attachmentURLs[attachment.id])), bytes)
        XCTAssertNil(target.pendingImportPreview)
    }

    @MainActor
    func testDraftMoveGuardsBothEndsAndSaveAsSnipKeepsAttachmentBytes() async throws {
        let library = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: library, defaults: defaults())
        _ = try await library.perform(.createList(name: "Work", systemImage: "folder"), sortedBy: .chronological)
        await model.reload()
        let work = try XCTUnwrap(model.lists.first { $0.name == "Work" })
        let url = try storeURL().deletingLastPathComponent().appendingPathComponent("draft.txt")
        let bytes = Data("Draft attachment".utf8)
        try bytes.write(to: url)
        model.saveComposerText("Source draft", for: SnipList.inboxID)
        model.addDraftAttachments([url], to: SnipList.inboxID)
        let sourceRead = try await model.handleCLIRequest(request(.showDraft(list: "Inbox"), model))
        let targetRead = try await model.handleCLIRequest(request(.showDraft(list: "Work"), model))
        let sourceRevision = try XCTUnwrap(data(sourceRead).drafts?.first?.revision)
        let destinationRevision = try XCTUnwrap(data(targetRead).drafts?.first?.revision)
        model.saveComposerText("Destination changed", for: work.id)
        do {
            _ = try await model.handleCLIRequest(request(.moveDraft(list: "Inbox", destination: "Work",
                expectedRevision: sourceRevision, expectedDestinationRevision: destinationRevision), model))
            XCTFail("A changed destination must invalidate the move")
        } catch SnipLibraryError.snipChanged {}
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "Source draft")
        let saved = try await model.handleCLIRequest(request(.saveDraftAsSnip(list: "Inbox",
            destination: "Work", expectedRevision: sourceRevision), model))
        XCTAssertEqual(saved.snips.first?.content, "Source draft")
        XCTAssertEqual(saved.snips.first?.listID, work.id)
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "")
        XCTAssertEqual(model.composerDraft(for: work.id).text, "Destination changed")
        let archive = try await library.archive()
        let attachment = try XCTUnwrap(archive.snips.first?.attachments.first)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archive.attachmentURLs[attachment.id])), bytes)
    }

    private func data(_ receipt: SnipCLIReceipt) throws -> SnipCLIDataResult {
        guard case .data(let result) = receipt.extendedResult else {
            throw XCTUnwrapError()
        }
        return result
    }

    @MainActor
    private func request(_ action: SnipCLIDataAction, _ model: AppModel) -> SnipCLIRequest {
        SnipCLIRequest(action: .extended(.data(action)), scopeToken: model.cliScopeToken)
    }
}

private struct XCTUnwrapError: Error {}
