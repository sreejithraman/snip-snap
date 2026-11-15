import Foundation
import SnipSnapCore
import XCTest
@testable import SnipSnapiOS

@MainActor
final class IOSSnipEditorDraftTests: IOSModelTestCase {
    func testOpenPickerBlocksDismissSaveAndBeginningAnotherEdit() async throws {
        for source in [AttachmentSource.files, .photos, .camera] {
            let first = Snip(content: "First", origin: .quickEntry)
            let second = Snip(content: "Second", origin: .quickEntry)
            let model = makeModel(library: ModelTestLibrary(snips: [first, second]))
            await model.load()
            let draft = try beginEditing(first, in: model)
            XCTAssertTrue(draft.canDismiss)
            XCTAssertTrue(draft.canSave)

            draft.presentAttachmentPicker(source)

            XCTAssertFalse(draft.canDismiss, "\(source)")
            XCTAssertFalse(draft.canSave, "\(source)")
            XCTAssertFalse(model.beginInlineSnipEdit(second), "\(source)")
            XCTAssertFalse(model.beginInlineSnipEdit(first), "\(source)")
            model.cancelInlineSnipEdit()
            XCTAssertTrue(model.snipEditorDraft === draft, "\(source)")

            draft.dismissAttachmentPicker(source)

            XCTAssertTrue(draft.canDismiss, "\(source)")
            XCTAssertTrue(draft.canSave, "\(source)")
            XCTAssertTrue(model.beginInlineSnipEdit(first), "\(source)")
            XCTAssertTrue(model.snipEditorDraft === draft, "\(source)")
            model.cancelInlineSnipEdit()
            XCTAssertNil(model.snipEditorDraft, "\(source)")
        }
    }

    func testReplaceTargetSurvivesTheClosedPickerAndUsesTheFirstPickedFile() async throws {
        let existingID = UUID()
        let attachment = try testAttachment(id: existingID, fileName: "existing.txt")
        let snip = Snip(content: "Files", origin: .quickEntry, attachments: [attachment])
        let model = makeModel(library: ModelTestLibrary(snips: [snip]))
        await model.load()
        let draft = try beginEditing(snip, in: model)
        defer { draft.discard() }
        try await stage(makeSourceFile("added.txt"), in: draft, using: model)
        let added = try XCTUnwrap(draft.attachments.last)
        let addedURL = try XCTUnwrap(added.url)

        draft.presentAttachmentPicker(.files, replacing: existingID)
        draft.dismissAttachmentPicker(.files)
        let picked = try [makeSourceFile("first-pick.txt"), makeSourceFile("second-pick.txt")]
        draft.stage(.success(picked), using: model)
        await waitUntilStagingStops(draft)

        XCTAssertEqual(draft.attachments.map(\.id), [existingID, added.id])
        XCTAssertEqual(draft.attachments[0].source, .replacement(attachmentID: existingID))
        XCTAssertEqual(draft.attachments[0].fileName, "first-pick.txt")
        XCTAssertNotNil(draft.attachments[0].url)
        XCTAssertEqual(draft.attachments[1], added)
        XCTAssertFalse(draft.attachments.contains { $0.fileName == "second-pick.txt" })

        draft.presentAttachmentPicker(.files, replacing: added.id)
        draft.dismissAttachmentPicker(.files)
        let replacement = try makeSourceFile("replacement.txt")
        draft.stage(.success([replacement]), using: model)
        await waitUntilStagingStops(draft)

        XCTAssertEqual(draft.attachments.map(\.id), [existingID, added.id])
        XCTAssertEqual(draft.attachments[1].source, .added)
        XCTAssertEqual(draft.attachments[1].fileName, "replacement.txt")
        XCTAssertNotEqual(draft.attachments[1].url, addedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: addedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: addedURL.deletingLastPathComponent().path))
        XCTAssertTrue(draft.canDismiss)
    }

    func testCancelledFilesPickPresentsNoErrorAndAppendsTheNextFile() async throws {
        let existingID = UUID()
        let attachment = try testAttachment(id: existingID, fileName: "existing.txt")
        let snip = Snip(content: "Files", origin: .quickEntry, attachments: [attachment])
        let model = makeModel(library: ModelTestLibrary(snips: [snip]))
        await model.load()
        let draft = try beginEditing(snip, in: model)
        defer { draft.discard() }
        let existing = try XCTUnwrap(draft.attachments.first)

        draft.presentAttachmentPicker(.files, replacing: existingID)
        draft.dismissAttachmentPicker(.files)
        draft.stage(.failure(CocoaError(.userCancelled)), using: model)

        XCTAssertNil(model.latestFailure)
        XCTAssertTrue(draft.canDismiss)
        try await stage(makeSourceFile("appended.txt"), in: draft, using: model)
        XCTAssertEqual(draft.attachments.count, 2)
        XCTAssertEqual(draft.attachments[0], existing)
        XCTAssertEqual(draft.attachments[1].source, .added)
        XCTAssertEqual(draft.attachments[1].fileName, "appended.txt")
    }

    func testFailedFilesPickPresentsAnImportError() async throws {
        let snip = Snip(content: "Files", origin: .quickEntry)
        let model = makeModel(library: ModelTestLibrary(snips: [snip]))
        await model.load()
        let draft = try beginEditing(snip, in: model)
        defer { draft.discard() }

        draft.presentAttachmentPicker(.files)
        draft.dismissAttachmentPicker(.files)
        draft.stage(.failure(CocoaError(.fileReadNoPermission)), using: model)

        XCTAssertEqual(model.latestFailure?.operation, "attachment.import_select")
        XCTAssertTrue(draft.attachments.isEmpty)
        XCTAssertTrue(draft.canDismiss)
    }

    func testStopImportAddsNothingAndRemovesItsBatch() async throws {
        let snip = Snip(content: "Files", origin: .quickEntry)
        let model = makeModel(library: ModelTestLibrary(snips: [snip]))
        await model.load()
        let draft = try beginEditing(snip, in: model)
        defer { draft.discard() }
        try await stage(makeSourceFile("kept.txt"), in: draft, using: model)
        let kept = try XCTUnwrap(draft.attachments.first)
        let stagingDirectory = try draftStagingDirectory(of: kept)
        let keptBatches = try FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)

        // Staging runs on the main actor, so it can't start before the stop.
        let stopped = try makeSourceFile("stopped.txt")
        draft.stageMedia(.files([stopped]), using: model)
        XCTAssertTrue(draft.isStaging)
        XCTAssertFalse(draft.canDismiss)
        draft.stopImport()
        await waitUntilStagingStops(draft)

        XCTAssertEqual(draft.attachments, [kept])
        XCTAssertNil(model.latestFailure)
        XCTAssertTrue(draft.canDismiss)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path), keptBatches)
    }

    func testDiscardDuringStagingAppliesNothingAndRemovesStagedFilesWhenStagingStops() async throws {
        let snip = Snip(content: "Files", origin: .quickEntry)
        let model = makeModel(library: ModelTestLibrary(snips: [snip]))
        await model.load()
        let draft = try beginEditing(snip, in: model)
        try await stage(makeSourceFile("kept.txt"), in: draft, using: model)
        let kept = try XCTUnwrap(draft.attachments.first)
        let stagingDirectory = try draftStagingDirectory(of: kept)

        let discarded = try makeSourceFile("discarded.txt")
        draft.stageMedia(.files([discarded]), using: model)
        model.finishInlineSnipEdit(draft)

        XCTAssertNil(model.snipEditorDraft)
        XCTAssertFalse(draft.canDismiss)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingDirectory.path))
        await waitUntilStagingStops(draft)
        XCTAssertEqual(draft.attachments, [kept])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    func testDiscardWhileIdleRemovesStagedFilesAtOnce() async throws {
        let snip = Snip(content: "Files", origin: .quickEntry)
        let model = makeModel(library: ModelTestLibrary(snips: [snip]))
        await model.load()
        let draft = try beginEditing(snip, in: model)
        try await stage(makeSourceFile("staged.txt"), in: draft, using: model)
        let stagingDirectory = try draftStagingDirectory(of: XCTUnwrap(draft.attachments.first))

        model.cancelInlineSnipEdit()

        XCTAssertNil(model.snipEditorDraft)
        XCTAssertFalse(draft.canDismiss)
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    func testDiscardDuringSaveKeepsStagedFilesUntilTheSaveEnds() async throws {
        let snip = Snip(content: "Files", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [snip], suspendsFirstCommand: true)
        let model = makeModel(library: library)
        await model.load()
        let draft = try beginEditing(snip, in: model)
        try await stage(makeSourceFile("saving.txt"), in: draft, using: model)
        let stagedURL = try XCTUnwrap(draft.attachments.first?.url)
        let stagingDirectory = try draftStagingDirectory(of: XCTUnwrap(draft.attachments.first))

        let save = Task { await draft.save(using: model) }
        await library.waitUntilFirstCommandStarts()
        XCTAssertTrue(draft.isSaving)
        model.finishInlineSnipEdit(draft)

        XCTAssertNil(model.snipEditorDraft)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        await library.resumeFirstCommand()
        _ = await save.value
        XCTAssertFalse(draft.isSaving)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    func testSuccessfulSaveRemovesTheStagingDirectory() async throws {
        let snip = Snip(content: "Files", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [snip])
        let model = makeModel(library: library)
        await model.load()
        let draft = try beginEditing(snip, in: model)
        defer { draft.discard() }
        try await stage(makeSourceFile("saved.txt"), in: draft, using: model)
        let stagedURL = try XCTUnwrap(draft.attachments.first?.url)
        let stagingDirectory = try draftStagingDirectory(of: XCTUnwrap(draft.attachments.first))

        let saved = await draft.save(using: model)

        XCTAssertTrue(saved)
        XCTAssertFalse(draft.isSaving)
        let edit = await library.lastAttachmentEdit
        XCTAssertEqual(edit?.edits, [.added(sourceURL: stagedURL)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    func testFailedSaveKeepsStagedFilesForARetry() async throws {
        let snip = Snip(content: "Files", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [snip])
        let model = makeModel(library: library)
        await model.load()
        let draft = try beginEditing(snip, in: model)
        defer { draft.discard() }
        try await stage(makeSourceFile("retry.txt"), in: draft, using: model)
        let stagedURL = try XCTUnwrap(draft.attachments.first?.url)
        // The model still shows the snip, so its save reaches a library that no longer has it.
        _ = try await library.perform(.delete(ids: [snip.id]), sortedBy: .chronological)

        let saved = await draft.save(using: model)

        XCTAssertFalse(saved)
        XCTAssertFalse(draft.isSaving)
        XCTAssertEqual(model.latestFailure?.operation, "snip.edit_attachments")
        XCTAssertTrue(model.snipEditorDraft === draft)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(draft.canSave)
    }

    func testAddedAttachmentPreviewBlocksDismissUntilItCloses() async throws {
        let snip = Snip(content: "Files", origin: .quickEntry)
        let model = makeModel(library: ModelTestLibrary(snips: [snip]))
        await model.load()
        let draft = try beginEditing(snip, in: model)
        defer { draft.discard() }
        try await stage(makeSourceFile("first.txt"), in: draft, using: model)
        try await stage(makeSourceFile("second.txt"), in: draft, using: model)
        let first = draft.attachments[0]
        let secondURL = try XCTUnwrap(draft.attachments[1].url)

        draft.previewAttachment(first, using: model)
        XCTAssertFalse(draft.canDismiss)
        _ = await TestReadiness.wait { draft.previewURL != nil }

        XCTAssertEqual(draft.previewURL, first.url)
        XCTAssertFalse(draft.canDismiss)
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(model.beginInlineSnipEdit(snip))

        draft.pageAttachmentPreview(to: secondURL)
        XCTAssertEqual(draft.previewURL, secondURL)
        XCTAssertFalse(draft.canDismiss)

        draft.dismissAttachmentPreview()
        XCTAssertNil(draft.previewURL)
        XCTAssertTrue(draft.canDismiss)
        XCTAssertTrue(draft.canSave)
    }

    func testPreviewOfARemovedAttachmentShowsNothing() async throws {
        let (model, handler, draft, existing) = try await makeExistingAttachmentEditor()
        defer { draft.discard() }

        draft.previewAttachment(existing, using: model)
        await handler.waitUntilPrepareStarts()
        draft.removeAttachment(id: existing.id)
        await handler.finishPrepare(with: .success(URL(fileURLWithPath: "/tmp/removed-preview.txt")))
        _ = await TestReadiness.wait { draft.canDismiss }

        XCTAssertTrue(draft.canDismiss)
        XCTAssertNil(draft.previewURL)
    }

    func testPreviewOfAReplacedAttachmentShowsNothing() async throws {
        let (model, handler, draft, existing) = try await makeExistingAttachmentEditor()
        defer { draft.discard() }

        draft.previewAttachment(existing, using: model)
        await handler.waitUntilPrepareStarts()
        draft.presentAttachmentPicker(.files, replacing: existing.id)
        draft.dismissAttachmentPicker(.files)
        let replacement = try makeSourceFile("replacement.txt")
        draft.stage(.success([replacement]), using: model)
        await waitUntilStagingStops(draft)
        XCTAssertEqual(draft.attachments.first?.source, .replacement(attachmentID: existing.id))
        await handler.finishPrepare(with: .success(URL(fileURLWithPath: "/tmp/replaced-preview.txt")))
        _ = await TestReadiness.wait { draft.canDismiss }

        XCTAssertTrue(draft.canDismiss)
        XCTAssertNil(draft.previewURL)
    }

    func testPreviewOfADiscardedDraftShowsNothing() async throws {
        let (model, handler, draft, existing) = try await makeExistingAttachmentEditor()
        let prepared = URL(fileURLWithPath: "/tmp/discarded-preview.txt")

        draft.previewAttachment(existing, using: model)
        await handler.waitUntilPrepareStarts()
        model.finishInlineSnipEdit(draft)
        await handler.finishPrepare(with: .success(prepared))
        // The preview resumes in the same main-actor job that records the prepared file.
        _ = await TestReadiness.wait { model.attachmentURL(for: existing.id) == prepared }
        await Task.yield()

        XCTAssertEqual(model.attachmentURL(for: existing.id), prepared)
        XCTAssertNil(draft.previewURL)
    }

    func testSecondPreviewWhilePreparingIsIgnored() async throws {
        let (model, handler, draft, existing) = try await makeExistingAttachmentEditor()
        defer { draft.discard() }
        let prepared = URL(fileURLWithPath: "/tmp/first-preview.txt")

        draft.previewAttachment(existing, using: model)
        await handler.waitUntilPrepareStarts()
        draft.previewAttachment(existing, using: model)
        await handler.finishPrepare(with: .success(prepared))
        _ = await TestReadiness.wait { draft.previewURL != nil }

        XCTAssertEqual(draft.previewURL, prepared)
        let prepareCount = await handler.prepareCount()
        XCTAssertEqual(prepareCount, 1)
        draft.dismissAttachmentPreview()
        XCTAssertTrue(draft.canDismiss)
    }

    func testPickedMediaForADiscardedDraftAddsNothing() async throws {
        let snip = Snip(content: "Files", origin: .quickEntry)
        let model = makeModel(library: ModelTestLibrary(snips: [snip]))
        await model.load()
        let draft = try beginEditing(snip, in: model)
        try await stage(makeSourceFile("staged.txt"), in: draft, using: model)
        let staged = try XCTUnwrap(draft.attachments.first)
        let stagingDirectory = try draftStagingDirectory(of: staged)
        model.cancelInlineSnipEdit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))

        let lateFiles = try makeSourceFile("late-files.txt")
        let lateMedia = try makeSourceFile("late-media.txt")
        draft.stage(.success([lateFiles]), using: model)
        await waitUntilStagingStops(draft)
        draft.stageMedia(.files([lateMedia]), using: model)
        await waitUntilStagingStops(draft)

        XCTAssertEqual(draft.attachments, [staged])
        XCTAssertNil(model.latestFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    // MARK: - Helpers

    private func beginEditing(_ snip: Snip, in model: IOSAppModel) throws -> SnipEditorDraft {
        XCTAssertTrue(model.beginInlineSnipEdit(snip))
        return try XCTUnwrap(model.snipEditorDraft)
    }

    /// An editor whose only attachment is an existing one that prepares through iCloud and waits.
    private func makeExistingAttachmentEditor() async throws -> (
        IOSAppModel, IOSCloudSyncHandlerProbe, SnipEditorDraft, AttachmentDraft
    ) {
        let attachmentID = UUID()
        let attachment = try testAttachment(id: attachmentID, fileName: "existing.txt")
        let snip = Snip(content: "Files", origin: .quickEntry, attachments: [attachment])
        let handler = IOSCloudSyncHandlerProbe(states: [attachmentID: .waiting])
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]), cloudSyncHandler: handler)
        await model.load()
        let draft = try beginEditing(snip, in: model)
        let existing = try XCTUnwrap(draft.attachments.first)
        XCTAssertEqual(existing.source, .existing(attachmentID: attachmentID))
        return (model, handler, draft, existing)
    }

    private func makeSourceFile(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSSnipEditorDraftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    /// Staged files sit at `<staging directory>/<batch>/<item>/<file name>`.
    private func draftStagingDirectory(of attachment: AttachmentDraft) throws -> URL {
        let directory = try XCTUnwrap(attachment.url)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func stage(_ url: URL, in draft: SnipEditorDraft, using model: IOSAppModel) async {
        draft.stageMedia(.files([url]), using: model)
        await waitUntilStagingStops(draft)
    }

    private func waitUntilStagingStops(_ draft: SnipEditorDraft) async {
        _ = await TestReadiness.wait { !draft.isStaging }
        XCTAssertFalse(draft.isStaging)
    }
}
