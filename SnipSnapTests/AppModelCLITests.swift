import XCTest
import SnipSnapCore
import Foundation
import AppKit
import UniformTypeIdentifiers
@testable import SnipSnap
@testable import SnipSnapPersistence

final class AppModelCLITests: StoreBackedTestCase {
    @MainActor
    func testAgentListCatalogPublisherFlushesListChangesInOrder() async throws {
        let imports = AgentImportStore(rootURL: try storeURL().deletingLastPathComponent())
        let publisher = AgentListCatalogPublisher(imports: imports)
        let research = SnipList(id: UUID(), name: "Research", systemImage: "books.vertical", position: 1)
        publisher.enqueue([.inbox, research])
        try await publisher.flush()
        let createdCatalog = await imports.availableLists()
        XCTAssertEqual(createdCatalog.map(\.id), [SnipList.inboxID, research.id])

        publisher.enqueue([.inbox])
        try await publisher.flush()
        let deletedCatalog = await imports.availableLists()
        XCTAssertEqual(deletedCatalog.map(\.id), [SnipList.inboxID])
    }

    @MainActor
    func testCatalogPublisherCanRecoverAfterFailedFlush() async throws {
        let root = try storeURL().deletingLastPathComponent()
        let imports = AgentImportStore(rootURL: root)
        let publisher = AgentListCatalogPublisher(imports: imports)
        let catalogURL = root.appendingPathComponent("Agent/scoped-catalog.json")
        try FileManager.default.createDirectory(
            at: catalogURL, withIntermediateDirectories: true
        )
        publisher.enqueue([.inbox], scopeToken: "account-a")
        do {
            try await publisher.flush()
            XCTFail("The directory occupying the catalog file must reject the write")
        } catch {}

        try FileManager.default.removeItem(at: catalogURL)
        publisher.enqueue([.inbox], scopeToken: "account-a")
        try await publisher.flush()
        let lists = try await imports.availableLists(matchingScopeToken: "account-a")
        XCTAssertEqual(lists.map(\.id), [SnipList.inboxID])
    }

    @MainActor
    func testCLIReadsSavedSnipsFromTheActiveLibrary() async throws {
        let library = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: library, defaults: defaults())
        _ = try await library.perform(
            .add(
                content: "Investigate export reliability", origin: .agent, source: nil,
                listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: Date()
            ),
            sortedBy: .chronological
        )

        let request = SnipCLIRequest(action: .listSnips(list: nil))
        let receipt = try await model.handleCLIRequest(request)

        XCTAssertEqual(receipt.status, .success)
        XCTAssertEqual(receipt.snips.map(\.content), ["Investigate export reliability"])
    }

    @MainActor
    func testCLIReadReportsUnavailableStore() async {
        let model = AppModel(library: JSONSnipLibrary.unavailable())
        do {
            _ = try await model.handleCLIRequest(SnipCLIRequest(action: .listSnips(list: nil)))
            XCTFail("CLI must not present a fallback snapshot as current data")
        } catch SnipLibraryError.storeUnavailable {}
        catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testCLIReconcilesAndSchedulesSyncWhenAWriteCommitsThenThrows() async throws {
        let snip = Snip(content: "Before", origin: .agent)
        let library = InMemorySnipLibrary(snips: [snip])
        let cloud = MacOptionalCloudSyncHandlerProbe()
        let model = AppModel(library: library, defaults: defaults(), cloudSyncHandler: cloud)
        await model.reload()
        await library.failAfterNextWrite()

        do {
            _ = try await model.handleCLIRequest(SnipCLIRequest(action: .updateSnip(
                id: snip.id, content: "Committed", expectedUpdatedAt: snip.updatedAt
            )))
            XCTFail("A post-commit failure must have an uncertain outcome.")
        } catch is SnipCLIOutcomeUncertain {}

        let stored = try await library.checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(stored.snips.first?.content, "Committed")
        XCTAssertEqual(model.snips.first?.content, "Committed")
        for _ in 0..<100 {
            if await cloud.syncCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let syncCount = await cloud.syncCount()
        XCTAssertEqual(syncCount, 1)
    }

    @MainActor
    func testAgentImportReconcilesAndSchedulesSyncWhenAddCommitsThenThrows() async throws {
        let library = InMemorySnipLibrary(snips: [])
        let cloud = MacOptionalCloudSyncHandlerProbe()
        let model = AppModel(library: library, defaults: defaults(), cloudSyncHandler: cloud)
        let request = AgentImportRequest(content: "  Committed add  ",
                                         destinationListID: UUID(),
                                         scopeToken: model.cliScopeToken)
        let imports = AgentImportStore(rootURL: try storeURL().deletingLastPathComponent())
        _ = try await imports.save(request)
        await library.failAfterNextWrite()
        let summary = await imports.importPending(activeScopeToken: model.cliScopeToken) { request in
            try await model.importAgentRequest(request)
        }
        XCTAssertEqual(summary.imported, 1)

        let stored = try await library.checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(stored.snips.first?.content, "Committed add")
        XCTAssertEqual(stored.snips.first?.listID, SnipList.inboxID)
        XCTAssertEqual(model.snips.first?.content, "Committed add")
        let snip = try XCTUnwrap(stored.snips.first)
        _ = try await library.perform(
            .update(id: snip.id, content: "Edited later", attachmentURLs: nil,
                    expectedUpdatedAt: snip.updatedAt, now: Date()),
            sortedBy: .chronological
        )
        let existing = try await imports.existingResult(for: request.requestID)
        guard case .completed(let receipt) = existing else {
            return XCTFail("The original add should have a durable receipt before later edits.")
        }
        XCTAssertEqual(receipt.snipID, snip.id)
        for _ in 0..<100 {
            if await cloud.syncCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let syncCount = await cloud.syncCount()
        XCTAssertEqual(syncCount, 1)
    }

    @MainActor
    func testAgentImportRetryAfterUnknownCommitAndLaterEdit() async throws {
        let library = InMemorySnipLibrary(snips: [])
        let model = AppModel(library: library, defaults: defaults())
        let request = AgentImportRequest(content: "  Original  ",
                                         destinationListID: SnipList.inboxID,
                                         scopeToken: model.cliScopeToken)
        let imports = AgentImportStore(rootURL: try storeURL().deletingLastPathComponent())
        _ = try await imports.save(request)
        await library.failAfterNextWriteAndRecoveryRead()
        let first = await imports.importPending(activeScopeToken: model.cliScopeToken) { request in
            try await model.importAgentRequest(request)
        }
        XCTAssertEqual(first.imported, 0)
        let pendingCount = await imports.pendingImportCount()
        XCTAssertEqual(pendingCount, 1)
        let afterCommit = try await library.checkedSnapshot(sortedBy: .chronological)
        let snip = try XCTUnwrap(afterCommit.snips.first)
        _ = try await library.perform(
            .update(id: snip.id, content: "Edited later", attachmentURLs: nil,
                    expectedUpdatedAt: snip.updatedAt, now: Date()),
            sortedBy: .chronological
        )
        let second = await imports.importPending(activeScopeToken: model.cliScopeToken) { request in
            try await model.importAgentRequest(request)
        }
        XCTAssertEqual(second.imported, 1)
        guard case .completed(let receipt) = try await imports.existingResult(
            for: request.requestID) else {
            return XCTFail("The retry should finish the original request.")
        }
        XCTAssertEqual(receipt.snipID, snip.id)
    }

    @MainActor
    func testCLIListSelectorsUseCanonicalNames() async throws {
        let model = AppModel(library: try JSONSnipLibrary(fileURL: storeURL()),
                             defaults: defaults())
        let spaced = try await model.handleCLIRequest(
            SnipCLIRequest(action: .createList(name: "A  B"))
        )
        let spacedID = try XCTUnwrap(spaced.lists.first?.id)
        let shownSpaced = try await model.handleCLIRequest(
            SnipCLIRequest(action: .showList(selector: " A   B "))
        )
        XCTAssertEqual(shownSpaced.lists.first?.id, spacedID)

        let research = try await model.handleCLIRequest(
            SnipCLIRequest(action: .createList(name: "Research"))
        )
        let researchID = try XCTUnwrap(research.lists.first?.id)
        let shownWidth = try await model.handleCLIRequest(
            SnipCLIRequest(action: .showList(selector: "Ｒｅｓｅａｒｃｈ"))
        )
        XCTAssertEqual(shownWidth.lists.first?.id, researchID)
    }

    @MainActor
    func testCLIUpdatesAndDeletesASavedSnip() async throws {
        let library = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: library, defaults: defaults())
        let added = try await library.perform(
            .add(content: "Old text", origin: .agent, source: nil,
                 listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: Date()),
            sortedBy: .chronological
        )
        let id = try XCTUnwrap(added.snapshot.snips.first?.id)
        let originalUpdatedAt = try XCTUnwrap(added.snapshot.snips.first?.updatedAt)

        let updated = try await model.handleCLIRequest(
            SnipCLIRequest(action: .updateSnip(id: id, content: "New text",
                                               expectedUpdatedAt: originalUpdatedAt))
        )
        XCTAssertEqual(updated.snips.first?.content, "New text")
        let shown = try await model.handleCLIRequest(
            SnipCLIRequest(action: .showSnip(id: id))
        )
        let revision = try XCTUnwrap(shown.snipRevisions[id.uuidString])
        let deleted = try await model.handleCLIRequest(
            SnipCLIRequest(action: .deleteSnip(id: id, expectedRevision: revision))
        )
        XCTAssertEqual(deleted.status, .success)
        let after = try await library.checkedSnapshot(sortedBy: .chronological)
        XCTAssertTrue(after.snips.isEmpty)
    }

    @MainActor
    func testCLICanClearTextWhileKeepingAnAttachment() async throws {
        let url = try storeURL()
        let source = url.deletingLastPathComponent().appendingPathComponent("cli-attachment.txt")
        try Data("Attachment".utf8).write(to: source)
        let library = try JSONSnipLibrary(fileURL: url)
        let added = try await library.add(
            content: "Remove this text", origin: .agent, attachmentURLs: [source]
        )
        let snip = try XCTUnwrap(added)
        let model = AppModel(library: library, defaults: defaults())
        let receipt = try await model.handleCLIRequest(SnipCLIRequest(action: .updateSnip(
            id: snip.id, content: "", expectedUpdatedAt: snip.updatedAt
        )))
        let updated = try XCTUnwrap(receipt.snips.first)
        XCTAssertEqual(updated.content, "")
        XCTAssertEqual(updated.attachments.map(\.id), snip.attachments.map(\.id))
    }

    @MainActor
    func testCLIRejectsStaleAndActiveEdits() async throws {
        let library = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: library, defaults: defaults())
        let added = try await library.perform(
            .add(content: "Original", origin: .agent, source: nil,
                 listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: Date()),
            sortedBy: .chronological
        )
        let snip = try XCTUnwrap(added.snapshot.snips.first)
        model.editingID = snip.id
        do {
            _ = try await model.handleCLIRequest(SnipCLIRequest(action: .deleteSnip(
                id: snip.id, expectedRevision: SnipCLIItemRevision.token(snip: snip))))
            XCTFail("CLI deletion should preserve the active editor")
        } catch SnipCLIRequestError.editingInProgress {}
        model.editingID = nil
        let changed = try await library.perform(
            .update(id: snip.id, content: "Newer", attachmentURLs: nil,
                    expectedUpdatedAt: snip.updatedAt, now: Date().addingTimeInterval(1)),
            sortedBy: .chronological
        )
        XCTAssertEqual(changed.snapshot.snips.first?.content, "Newer")
        do {
            _ = try await model.handleCLIRequest(SnipCLIRequest(action: .updateSnip(
                id: snip.id, content: "Stale", expectedUpdatedAt: snip.updatedAt)))
            XCTFail("CLI update should reject stale content")
        } catch SnipLibraryError.snipChanged {}
        let changedSnip = try XCTUnwrap(changed.snapshot.snips.first)
        let revision = SnipCLIItemRevision.token(snip: changedSnip)
        _ = try await library.perform(.toggleDone(id: snip.id), sortedBy: .chronological)
        do {
            _ = try await model.handleCLIRequest(SnipCLIRequest(action: .deleteSnip(
                id: snip.id, expectedRevision: revision)))
            XCTFail("CLI delete should reject a metadata change")
        } catch SnipLibraryError.snipChanged {}
    }

    @MainActor
    func testCLIListCRUDMovesSnipsToInboxWhenDeleted() async throws {
        let library = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: library, defaults: defaults())
        let created = try await model.handleCLIRequest(
            SnipCLIRequest(action: .createList(name: "Research"))
        )
        let listID = try XCTUnwrap(created.lists.first?.id)
        model.saveComposerText("Draft for Research", for: listID)
        _ = try await library.perform(
            .add(content: "Read paper", origin: .agent, source: nil,
                 listID: listID, attachmentURLs: [], requestID: UUID(), now: Date()),
            sortedBy: .chronological
        )
        let shown = try await model.handleCLIRequest(
            SnipCLIRequest(action: .showList(selector: "Research"))
        )
        XCTAssertEqual(shown.snips.map(\.content), ["Read paper"])
        let revision = try XCTUnwrap(shown.listRevision)
        let renamed = try await model.handleCLIRequest(
            SnipCLIRequest(action: .updateList(
                id: listID, name: "Reading", expectedRevision: revision))
        )
        XCTAssertEqual(renamed.lists.first?.name, "Reading")
        let renamedView = try await model.handleCLIRequest(
            SnipCLIRequest(action: .showList(selector: "Reading"))
        )
        let attachment = try storeURL().deletingLastPathComponent()
            .appendingPathComponent("unsaved-draft-attachment.txt")
        try Data("unsaved".utf8).write(to: attachment)
        model.addTemporaryDraftAttachment(attachment, to: listID)
        do {
            _ = try await model.handleCLIRequest(SnipCLIRequest(action: .deleteList(
                id: listID, expectedRevision: try XCTUnwrap(renamedView.listRevision))))
            XCTFail("CLI must preserve unseen draft content.")
        } catch SnipCLIRequestError.draftInProgress {}
        XCTAssertEqual(model.composerDraft(for: listID).text, "Draft for Research")
        XCTAssertEqual(model.composerDraft(for: listID).attachments, [attachment])
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path))
        model.clearDraft(for: listID)
        _ = try await model.handleCLIRequest(
            SnipCLIRequest(action: .deleteList(
                id: listID, expectedRevision: try XCTUnwrap(renamedView.listRevision)))
        )
        let after = try await library.checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(after.snips.first?.listID, SnipList.inboxID)
        XCTAssertEqual(model.composerDraft(for: listID).text, "")
    }

    @MainActor
    func testCLIListDeletionPreservesDraftWrittenWhileLibraryIsSuspended() async throws {
        let source = SnipList(id: UUID(), name: "Research", systemImage: "folder", position: 1)
        let library = InMemorySnipLibrary(
            snips: [], lists: [.inbox, source], suspendsFirstCommand: true
        )
        let model = AppModel(library: library, defaults: defaults())
        model.saveComposerText("Existing Inbox", for: SnipList.inboxID)
        let inboxAttachment = try storeURL().deletingLastPathComponent()
            .appendingPathComponent("existing-inbox.txt")
        try Data("inbox".utf8).write(to: inboxAttachment)
        model.addTemporaryDraftAttachment(inboxAttachment, to: SnipList.inboxID)
        let shown = try await model.handleCLIRequest(
            SnipCLIRequest(action: .showList(selector: source.id.uuidString))
        )
        let revision = try XCTUnwrap(shown.listRevision)
        let deletion = Task { @MainActor in
            try await model.handleCLIRequest(SnipCLIRequest(action: .deleteList(
                id: source.id, expectedRevision: revision)))
        }
        await library.waitUntilFirstCommandStarts()
        let attachment = try storeURL().deletingLastPathComponent()
            .appendingPathComponent("during-delete.txt")
        try Data("attachment".utf8).write(to: attachment)
        model.saveComposerText("Draft during delete", for: source.id)
        model.addTemporaryDraftAttachment(attachment, to: source.id)
        await library.resumeFirstCommand()
        _ = try await deletion.value

        let inboxDraft = model.composerDraft(for: SnipList.inboxID)
        XCTAssertEqual(inboxDraft.text, "Existing Inbox\n\nDraft during delete")
        XCTAssertEqual(inboxDraft.attachments, [inboxAttachment, attachment])
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path))
        XCTAssertEqual(model.composerDraft(for: source.id).text, "")
        let late = try storeURL().deletingLastPathComponent()
            .appendingPathComponent("late-paste.txt")
        try Data("late".utf8).write(to: late)
        model.addTemporaryDraftAttachment(late, to: source.id)
        model.saveComposerText("Draft during delete", for: source.id)
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text,
                       "Existing Inbox\n\nDraft during delete")
        model.saveComposerText("Draft changed", for: source.id)
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text,
                       "Existing Inbox\n\nDraft changed")
        model.saveComposerText("", for: source.id)
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "Existing Inbox")
        model.saveComposerText("Late text", for: source.id)
        model.saveComposerText("Late text expanded", for: source.id)
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).attachments,
                       [inboxAttachment, attachment, late])
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text,
                       "Existing Inbox\n\nLate text expanded")
        let saved = await model.saveComposerDraft(content: "Stale send", listID: source.id)
        XCTAssertFalse(saved)
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text,
                       "Existing Inbox\n\nLate text expanded")
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).attachments,
                       [inboxAttachment, attachment, late])

        model.saveComposerText("My Inbox edit ends with Late text expanded", for: SnipList.inboxID)
        model.saveComposerText("Later source callback", for: source.id)
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text,
                       "My Inbox edit ends with Late text expanded\n\nLater source callback")
    }

    @MainActor
    func testCLIListPostCommitFailureStillMovesDraftToInbox() async throws {
        let source = SnipList(id: UUID(), name: "Research", systemImage: "folder", position: 1)
        let library = InMemorySnipLibrary(
            snips: [], lists: [.inbox, source], suspendsFirstCommand: true
        )
        let model = AppModel(library: library, defaults: defaults())
        let shown = try await model.handleCLIRequest(
            SnipCLIRequest(action: .showList(selector: source.id.uuidString))
        )
        let revision = try XCTUnwrap(shown.listRevision)
        await library.failAfterNextWriteAndRecoveryRead()
        let deletion = Task { @MainActor in
            try await model.handleCLIRequest(SnipCLIRequest(action: .deleteList(
                id: source.id, expectedRevision: revision)))
        }
        await library.waitUntilFirstCommandStarts()
        let attachment = try storeURL().deletingLastPathComponent()
            .appendingPathComponent("uncertain-delete.txt")
        try Data("attachment".utf8).write(to: attachment)
        model.saveComposerText("Draft during uncertain delete", for: source.id)
        model.addTemporaryDraftAttachment(attachment, to: source.id)
        await library.resumeFirstCommand()
        do {
            _ = try await deletion.value
            XCTFail("The commit with a persistence error must remain uncertain.")
        } catch is SnipCLIOutcomeUncertain {}
        XCTAssertEqual(model.composerDraft(for: source.id).text,
                       "Draft during uncertain delete")
        await model.reload()
        XCTAssertFalse(model.lists.contains(where: { $0.id == source.id }))
        let inbox = model.composerDraft(for: SnipList.inboxID)
        XCTAssertEqual(inbox.text, "Draft during uncertain delete")
        XCTAssertEqual(inbox.attachments, [attachment])
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path))
    }

    @MainActor
    func testFailedDeleteDoesNotMoveDraftFromExistingList() async throws {
        let source = SnipList(id: UUID(), name: "Research", systemImage: "folder", position: 1)
        let library = InMemorySnipLibrary(
            snips: [], lists: [.inbox, source], suspendsFirstCommand: true
        )
        let model = AppModel(library: library, defaults: defaults())
        let shown = try await model.handleCLIRequest(
            SnipCLIRequest(action: .showList(selector: source.id.uuidString))
        )
        await library.failBeforeNextWriteAndRecoveryRead()
        let deletion = Task { @MainActor in
            try await model.handleCLIRequest(SnipCLIRequest(action: .deleteList(
                id: source.id, expectedRevision: try XCTUnwrap(shown.listRevision))))
        }
        await library.waitUntilFirstCommandStarts()
        model.saveComposerText("Keep with Research", for: source.id)
        await library.resumeFirstCommand()
        do {
            _ = try await deletion.value
            XCTFail("Failed deletion with failed recovery read must be uncertain.")
        } catch is SnipCLIOutcomeUncertain {}
        XCTAssertTrue(model.lists.contains(where: { $0.id == source.id }))
        XCTAssertEqual(model.composerDraft(for: source.id).text, "Keep with Research")
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "")
    }

    @MainActor
    func testFallbackReloadDoesNotTreatCloudListAsDeleted() async throws {
        let source = SnipList(id: UUID(), name: "Research", systemImage: "folder", position: 1)
        let library = InMemorySnipLibrary(snips: [], lists: [.inbox, source])
        let model = AppModel(library: library, defaults: defaults())
        await model.reload()
        model.saveComposerText("Keep with Research", for: source.id)
        await library.returnFallbackSnapshotAndFailCheckedRead()
        await model.reload()
        XCTAssertTrue(model.lists.contains(where: { $0.id == source.id }))
        XCTAssertEqual(model.composerDraft(for: source.id).text, "Keep with Research")
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "")
    }

    @MainActor
    func testLibraryReplacementKeepsPriorLibraryDraftIsolated() async throws {
        let source = SnipList(id: UUID(), name: "Research", systemImage: "folder", position: 1)
        let oldLibrary = InMemorySnipLibrary(snips: [], lists: [.inbox, source])
        let replacement = InMemorySnipLibrary(snips: [], lists: [.inbox])
        let oldScope = SnipRecoveryScope("account-a")
        let newScope = SnipRecoveryScope("account-b")
        let model = AppModel(
            library: oldLibrary, defaults: defaults(), recoveryScope: oldScope
        )
        await model.reload()
        model.saveComposerText("Research draft", for: source.id)
        model.saveComposerText("Old Inbox", for: SnipList.inboxID)
        let attachment = try storeURL().deletingLastPathComponent()
            .appendingPathComponent("replacement-draft.txt")
        try Data("attachment".utf8).write(to: attachment)
        model.addTemporaryDraftAttachment(attachment, to: source.id)
        let inboxAttachment = try storeURL().deletingLastPathComponent()
            .appendingPathComponent("replacement-inbox.txt")
        try Data("inbox".utf8).write(to: inboxAttachment)
        model.addTemporaryDraftAttachment(inboxAttachment, to: SnipList.inboxID)

        await model.replaceLibrary(replacement, recoveryScope: newScope)
        XCTAssertFalse(model.lists.contains(where: { $0.id == source.id }))
        XCTAssertEqual(model.composerDraft(for: source.id).text, "")
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "")
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).attachments, [])
        model.saveComposerText("Late prior-account text", for: source.id)
        let staleSendSaved = await model.saveComposerDraft(
            content: "Stale send", listID: SnipList.inboxID,
            expectedScope: oldScope.rawValue
        )
        XCTAssertFalse(staleSendSaved)
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "")
        model.saveComposerText("New Inbox", for: SnipList.inboxID)
        await model.reload()
        XCTAssertFalse(model.lists.contains(where: { $0.id == source.id }))
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "New Inbox")
        await model.replaceLibrary(oldLibrary, recoveryScope: oldScope)
        XCTAssertTrue(model.lists.contains(where: { $0.id == source.id }))
        XCTAssertEqual(model.composerDraft(for: source.id).text, "Research draft")
        XCTAssertEqual(model.composerDraft(for: source.id).attachments, [attachment])
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "Old Inbox")
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).attachments, [inboxAttachment])
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path))
    }

    @MainActor
    func testSameScopeLibraryReplacementRecoversRemovedListDraftOnCheckedReload() async throws {
        let source = SnipList(id: UUID(), name: "Research", systemImage: "folder", position: 1)
        let scope = SnipRecoveryScope("same-account")
        let oldLibrary = InMemorySnipLibrary(snips: [], lists: [.inbox, source])
        let replacement = InMemorySnipLibrary(snips: [], lists: [.inbox])
        let model = AppModel(library: oldLibrary, defaults: defaults(), recoveryScope: scope)
        await model.reload()
        model.saveComposerText("Keep this draft", for: source.id)

        await model.replaceLibrary(replacement, recoveryScope: scope)
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "Keep this draft")
        XCTAssertEqual(model.composerDraft(for: source.id).text, "")
    }

    @MainActor
    func testReturningToPreviousLibraryRecoversDraftForListDeletedWhileAway() async throws {
        let source = SnipList(
            id: UUID(), name: "Account A notes", systemImage: "folder", position: 1
        )
        let accountA = InMemorySnipLibrary(snips: [], lists: [.inbox, source])
        let accountB = InMemorySnipLibrary(snips: [])
        let scopeA = SnipRecoveryScope("account-a")
        let scopeB = SnipRecoveryScope("account-b")
        let model = AppModel(library: accountA, defaults: defaults(), recoveryScope: scopeA)
        model.saveComposerText("Keep this draft", for: source.id)

        await model.replaceLibrary(accountB, recoveryScope: scopeB)
        _ = try await accountA.perform(
            .deleteList(id: source.id), sortedBy: .chronological
        )
        await model.replaceLibrary(accountA, recoveryScope: scopeA)

        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "Keep this draft")
        XCTAssertEqual(model.composerDraft(for: source.id).text, "")
    }

    @MainActor
    func testTypingWhileComposerSendWaitsForLockPreservesNewDraftText() async throws {
        let library = InMemorySnipLibrary(snips: [])
        let model = AppModel(library: library, defaults: defaults())
        await model.reload()
        model.saveComposerText("Send this", for: SnipList.inboxID)

        let gate = ModelCommandLockGate()
        let holder = Task { @MainActor in
            await model.withCommandLock { await gate.hold() }
        }
        await gate.waitUntilHeld()
        let send = Task { @MainActor in
            await model.saveComposerDraft(content: "Send this", listID: SnipList.inboxID)
        }
        await Task.yield()
        model.saveComposerText("Keep editing this", for: SnipList.inboxID)
        await gate.release()
        await holder.value
        let saved = await send.value
        XCTAssertTrue(saved)

        let snapshot = try await library.checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(snapshot.snips.map(\.content), ["Send this"])
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "Keep editing this")
    }

    @MainActor
    func testQueuedAddCannotImportIntoReplacementAccount() async throws {
        let firstScope = SnipRecoveryScope("account-a")
        let secondScope = SnipRecoveryScope("account-b")
        let first = InMemorySnipLibrary(snips: [])
        let second = InMemorySnipLibrary(snips: [])
        let model = AppModel(library: first, defaults: defaults(), recoveryScope: firstScope)
        let request = AgentImportRequest(
            content: "Account A idea", destinationListID: SnipList.inboxID,
            scopeToken: model.cliScopeToken
        )

        await model.replaceLibrary(second, recoveryScope: secondScope)
        do {
            _ = try await model.importAgentRequest(request)
            XCTFail("The queued add must stay in its original account")
        } catch SnipCLIRequestError.scopeChanged {}
        let secondSnapshot = try await second.checkedSnapshot(sortedBy: .chronological)
        XCTAssertTrue(secondSnapshot.snips.isEmpty)

        await model.replaceLibrary(first, recoveryScope: firstScope)
        let receipt = try await model.importAgentRequest(request)
        XCTAssertEqual(receipt.status, .added)
        let firstSnapshot = try await first.checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(firstSnapshot.snips.map(\.content), ["Account A idea"])
    }

    @MainActor
    func testUnattributedQueuedAddWaitsForExplicitInboxChoice() async throws {
        let library = InMemorySnipLibrary(snips: [])
        let imports = AgentImportStore(rootURL: try storeURL().deletingLastPathComponent())
        let model = AppModel(
            library: library, defaults: defaults(),
            recoveryScope: SnipRecoveryScope("current-account"),
            agentImports: imports
        )
        let request = AgentImportRequest(
            content: "Unattributed idea", destinationListID: UUID()
        )
        _ = try await imports.save(request)
        let skipped = await imports.importPending(activeScopeToken: model.cliScopeToken) { _ in
            XCTFail("Unattributed add must wait for a library choice")
            throw AgentImportError.invalidRequest
        }
        XCTAssertEqual(skipped, AgentImportSummary(imported: 0, failed: 0))
        await model.refreshQueuedAddsRequiringAttention()
        XCTAssertEqual(model.needsAttentionCount, 1)
        let before = try await library.checkedSnapshot(sortedBy: .chronological)
        XCTAssertTrue(before.snips.isEmpty)

        await model.addQueuedRequestToThisInbox(request.requestID)

        let after = try await library.checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(after.snips.map(\.content), ["Unattributed idea"])
        XCTAssertEqual(after.snips.first?.listID, SnipList.inboxID)
        XCTAssertEqual(model.needsAttentionCount, 0)
        let pendingCount = await imports.pendingImportCount()
        XCTAssertEqual(pendingCount, 0)
    }

    @MainActor
    func testQueuedAddFromPreviousLibraryAppearsForExplicitReview() async throws {
        let library = InMemorySnipLibrary(snips: [])
        let imports = AgentImportStore(rootURL: try storeURL().deletingLastPathComponent())
        let model = AppModel(
            library: library, defaults: defaults(),
            recoveryScope: SnipRecoveryScope("account-b"),
            agentImports: imports
        )
        let request = AgentImportRequest(
            content: "Previous library idea", destinationListID: UUID(),
            scopeToken: "account-a"
        )
        _ = try await imports.save(request)
        let skipped = await imports.importPending(activeScopeToken: model.cliScopeToken) { _ in
            XCTFail("The previous account's add must not import automatically")
            throw AgentImportError.invalidRequest
        }
        XCTAssertEqual(skipped, AgentImportSummary(imported: 0, failed: 0))
        await model.refreshQueuedAddsRequiringAttention()
        XCTAssertEqual(model.queuedAddsRequiringAttention.map(\.requestID), [request.requestID])
        XCTAssertEqual(model.needsAttentionCount, 1)

        await model.addQueuedRequestToThisInbox(request.requestID)

        let snapshot = try await library.checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(snapshot.snips.map(\.content), ["Previous library idea"])
        XCTAssertEqual(snapshot.snips.first?.listID, SnipList.inboxID)
        XCTAssertEqual(model.needsAttentionCount, 0)
        let receipt = try await imports.receipt(for: request.requestID)
        XCTAssertEqual(receipt?.requestScopeToken, "account-a")
        XCTAssertEqual(receipt?.approvedInboxScopeToken, model.cliScopeToken)
    }

    @MainActor
    func testPendingInboxSendNeverWritesToReplacementLibrary() async throws {
        let oldScope = SnipRecoveryScope("account-a")
        let newScope = SnipRecoveryScope("account-b")
        let oldLibrary = InMemorySnipLibrary(snips: [])
        let replacement = InMemorySnipLibrary(snips: [])
        let model = AppModel(
            library: oldLibrary, defaults: defaults(), recoveryScope: oldScope
        )
        await model.reload()
        model.saveComposerText("Account A pending send", for: SnipList.inboxID)

        let gate = ModelCommandLockGate()
        let holder = Task { @MainActor in
            await model.withCommandLock { await gate.hold() }
        }
        await gate.waitUntilHeld()
        let replacementTask = Task { @MainActor in
            await model.replaceLibrary(replacement, recoveryScope: newScope)
        }
        await Task.yield()
        let send = Task { @MainActor in
            await model.saveComposerDraft(
                content: "Account A pending send", listID: SnipList.inboxID,
                expectedScope: oldScope.rawValue
            )
        }
        await gate.release()
        await holder.value
        await replacementTask.value
        _ = await send.value

        let newSnapshot = try await replacement.checkedSnapshot(sortedBy: .chronological)
        XCTAssertTrue(newSnapshot.snips.isEmpty)
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "")
    }

    @MainActor
    func testCLIRequestFromPriorAccountCannotMutateReplacementLibrary() async throws {
        let oldScope = SnipRecoveryScope("account-a")
        let newScope = SnipRecoveryScope("account-b")
        let oldLibrary = InMemorySnipLibrary(snips: [])
        let replacement = InMemorySnipLibrary(snips: [])
        let model = AppModel(
            library: oldLibrary, defaults: defaults(), recoveryScope: oldScope
        )
        let request = SnipCLIRequest(
            action: .createList(name: "Account A list"),
            scopeToken: model.cliScopeToken
        )
        await model.replaceLibrary(replacement, recoveryScope: newScope)
        do {
            _ = try await model.handleCLIRequest(request)
            XCTFail("A prior-account command must not run in the new library.")
        } catch SnipCLIRequestError.scopeChanged {}
        let snapshot = try await replacement.checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(snapshot.lists.map(\.id), [SnipList.inboxID])
    }

    @MainActor
    func testFailedCheckedReloadRefreshesRecoveryAfterFailure() async throws {
        let current = Snip(content: "Current", origin: .quickEntry)
        let recovered = RecoveredSnip(
            id: UUID(), currentSnipID: current.id,
            recovered: Snip(content: "Recovered", origin: .quickEntry),
            conflictingFields: [.text]
        )
        let library = InMemorySnipLibrary(snips: [current])
        let model = AppModel(
            library: library, defaults: defaults(),
            recoveryScope: SnipRecoveryScope("failed-read")
        )
        await model.reload()
        XCTAssertEqual(model.needsAttentionCount, 0)
        await library.failNextCheckedRead(
            recording: SnipRecoverySnapshot(pendingSnips: [recovered])
        )
        await model.reload()
        XCTAssertEqual(model.snips.map(\.id), [current.id])
        XCTAssertEqual(model.needsAttentionCount, 1)
    }

    @MainActor
    func testCLIRejectsStaleListRenameAndMembershipDelete() async throws {
        let library = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: library, defaults: defaults())
        let created = try await model.handleCLIRequest(
            SnipCLIRequest(action: .createList(name: "Research"))
        )
        let id = try XCTUnwrap(created.lists.first?.id)
        let shown = try await model.handleCLIRequest(
            SnipCLIRequest(action: .showList(selector: "Research"))
        )
        let oldRevision = try XCTUnwrap(shown.listRevision)
        _ = try await library.perform(
            .updateList(id: id, name: "Reading", systemImage: "circle.grid.2x2.fill"),
            sortedBy: .chronological
        )
        do {
            _ = try await model.handleCLIRequest(SnipCLIRequest(action: .updateList(
                id: id, name: "Overwrite", expectedRevision: oldRevision)))
            XCTFail("A stale list rename must fail")
        } catch SnipLibraryError.snipChanged {}

        let fresh = try await model.handleCLIRequest(
            SnipCLIRequest(action: .showList(selector: "Reading"))
        )
        let beforeMembership = try XCTUnwrap(fresh.listRevision)
        _ = try await library.perform(
            .add(content: "New member", origin: .agent, source: nil, listID: id,
                 attachmentURLs: [], requestID: UUID(), now: Date()),
            sortedBy: .chronological
        )
        do {
            _ = try await model.handleCLIRequest(SnipCLIRequest(action: .deleteList(
                id: id, expectedRevision: beforeMembership)))
            XCTFail("A stale list delete must fail")
        } catch SnipLibraryError.snipChanged {}
    }

}

private actor ModelCommandLockGate {
    private var isHeld = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        isHeld = true
        heldWaiters.forEach { $0.resume() }
        heldWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilHeld() async {
        if isHeld { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
