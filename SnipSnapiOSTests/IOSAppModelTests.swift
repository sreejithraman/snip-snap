import SnipSnapCore
import SnipSnapPersistence
import XCTest
@testable import SnipSnapiOS

@MainActor
final class IOSAppModelTests: XCTestCase {
    func testAttachmentDraftCleanupWaitsForChildPresentations() {
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsDismissal(isSaving: false, isStaging: true)
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsDismissal(isSaving: true, isStaging: false)
        )
        XCTAssertTrue(
            AttachmentDraftLifecycle.allowsDismissal(isSaving: false, isStaging: false)
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: true,
                isStaging: false,
                isImporting: false,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: true,
                isImporting: false,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: false,
                isImporting: true,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: false,
                isImporting: false,
                isPreviewing: true
            )
        )
        XCTAssertTrue(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: false,
                isImporting: false,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.shouldClean(
                isSaving: false,
                isStaging: false,
                isImporting: true,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.shouldClean(
                isSaving: false,
                isStaging: false,
                isImporting: false,
                isPreviewing: true
            )
        )
        XCTAssertTrue(
            AttachmentDraftLifecycle.shouldClean(
                isSaving: false,
                isStaging: false,
                isImporting: false,
                isPreviewing: false
            )
        )
    }

    func testTextSnipFlowCreatesEditsMovesAndDeletes() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        await model.load()

        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let workID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)
        let createdSnip = await model.createSnip(content: "First draft", in: SnipList.inboxID)
        XCTAssertTrue(createdSnip)
        let snip = try XCTUnwrap(model.selectedSnip)

        let editedSnip = await model.editSnip(snip, content: "Final draft")
        XCTAssertTrue(editedSnip)
        XCTAssertEqual(model.selectedSnip?.content, "Final draft")

        let movedSnip = await model.moveSnip(id: snip.id, to: workID)
        XCTAssertTrue(movedSnip)
        XCTAssertEqual(model.selectedListID, workID)
        XCTAssertEqual(model.selectedSnip?.listID, workID)

        let deletedSnip = await model.deleteSnip(id: snip.id)
        XCTAssertTrue(deletedSnip)
        XCTAssertTrue(model.snips.isEmpty)
        XCTAssertNil(model.selectedSnipID)
        let pruneCalls = await library.pruneCalls()
        XCTAssertEqual(pruneCalls, 6)
    }

    func testReloadPrunesWithNoUndoAttachmentLeases() async {
        let library = ModelTestLibrary()
        let firstModel = IOSAppModel(library: library)
        _ = await firstModel.createSnip(content: "Saved", in: SnipList.inboxID)

        let reloadedModel = IOSAppModel(library: library)
        await reloadedModel.load()

        let retentionCalls = await library.retentionCalls()
        XCTAssertEqual(retentionCalls.last, Set<UUID>())
    }

    func testUndoHistoryEvictsItsOldestAttachmentLease() throws {
        var history = IOSUndoHistory()
        var attachmentIDs: [UUID] = []
        let empty = SnipLibrarySnapshot(snips: [], lists: [.inbox])

        for index in 0...100 {
            let attachmentID = UUID()
            attachmentIDs.append(attachmentID)
            let attachment = try testAttachment(id: attachmentID, fileName: "file-\(index).txt")
            let snip = Snip(
                content: "File \(index)",
                origin: .quickEntry,
                attachments: [attachment]
            )
            let before = SnipLibrarySnapshot(snips: [snip], lists: [.inbox])
            history.record(
                name: "Delete",
                before: before,
                after: empty,
                touchedListIDs: [],
                inverse: .restore(snips: [snip]),
                selection: .init(listID: SnipList.inboxID, snipID: snip.id, snipIDs: [])
            )
        }

        XCTAssertEqual(history.retainedAttachmentIDs.count, 100)
        XCTAssertFalse(history.retainedAttachmentIDs.contains(attachmentIDs[0]))
        XCTAssertTrue(history.retainedAttachmentIDs.contains(attachmentIDs[100]))
    }

    func testDeletedSnipUndoRestoresReadableAttachment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapUndoAttachment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.txt")
        try Data("Restore me".utf8).write(to: sourceURL)
        let library = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("snips.json"))
        let model = IOSAppModel(library: library)
        await model.load()

        let created = await model.createSnip(
            content: "",
            in: SnipList.inboxID,
            attachmentURLs: [sourceURL]
        )
        XCTAssertTrue(created)
        let snip = try XCTUnwrap(model.selectedSnip)
        let attachmentID = try XCTUnwrap(snip.attachments.first?.id)
        let storedURL = try XCTUnwrap(model.attachmentURL(for: attachmentID))
        let deleted = await model.deleteSnip(id: snip.id)
        XCTAssertTrue(deleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))

        let undone = await model.undo()
        XCTAssertTrue(undone)
        let restoredURL = try XCTUnwrap(model.attachmentURL(for: attachmentID))
        XCTAssertEqual(try Data(contentsOf: restoredURL), Data("Restore me".utf8))
    }

    func testRejectedUndoReleasesDeletedSnipAttachment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapRejectedUndo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.txt")
        try Data("Release me".utf8).write(to: sourceURL)
        let library = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("snips.json"))
        let model = IOSAppModel(library: library)
        await model.load()

        let madeList = await model.createList(name: "Work")
        XCTAssertTrue(madeList)
        let listID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)
        let created = await model.createSnip(
            content: "",
            in: listID,
            attachmentURLs: [sourceURL]
        )
        XCTAssertTrue(created)
        let snip = try XCTUnwrap(model.selectedSnip)
        let storedURL = try XCTUnwrap(model.attachmentURL(for: snip.attachments[0].id))
        let deleted = await model.deleteSnip(id: snip.id)
        XCTAssertTrue(deleted)
        _ = try await library.perform(.deleteList(id: listID), sortedBy: .manual)

        let undone = await model.undo()
        XCTAssertFalse(undone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
    }

    func testListFlowKeepsInboxAsFallback() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        await model.load()

        let createdList = await model.createList(name: "Notes")
        XCTAssertTrue(createdList)
        let list = try XCTUnwrap(model.lists.first(where: { $0.name == "Notes" }))
        let createdSnip = await model.createSnip(content: "Keep me", in: list.id)
        XCTAssertTrue(createdSnip)
        let renamedList = await model.renameList(list, name: "Ideas")
        XCTAssertTrue(renamedList)
        XCTAssertEqual(model.lists.first(where: { $0.id == list.id })?.name, "Ideas")

        let deletedList = await model.deleteList(id: list.id)
        XCTAssertTrue(deletedList)
        XCTAssertEqual(model.selectedListID, SnipList.inboxID)
        XCTAssertEqual(model.snips.first?.listID, SnipList.inboxID)
        XCTAssertEqual(model.lists.first, .inbox)
    }

    func testAttachmentInputsUseTheTargetedLibraryCommands() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        await model.load()
        let sourceURL = URL(fileURLWithPath: "/tmp/first-file.txt")
        let replacementURL = URL(fileURLWithPath: "/tmp/replacement-file.txt")

        let created = await model.createSnip(
            content: "",
            in: SnipList.inboxID,
            attachmentURLs: [sourceURL]
        )
        XCTAssertTrue(created)
        let addedURLs = await library.addedAttachmentURLs()
        XCTAssertEqual(addedURLs, [sourceURL])
        let snip = try XCTUnwrap(model.selectedSnip)

        let edited = await model.editSnip(
            snip,
            content: "Now with a file",
            attachmentEdits: [.added(sourceURL: replacementURL)]
        )
        XCTAssertTrue(edited)
        let edit = await library.lastAttachmentEdit
        XCTAssertEqual(edit?.snipID, snip.id)
        XCTAssertEqual(edit?.content, "Now with a file")
        XCTAssertEqual(edit?.edits, [.added(sourceURL: replacementURL)])
    }

    func testAttachmentDraftStagingCopiesAndCleansTemporaryInput() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapDraftStagingTests-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapDraftSourceTests-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = sourceRoot.appendingPathComponent("draft.txt")
        defer {
            AttachmentDraftStager.clean(testRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("Draft bytes".utf8).write(to: sourceURL)

        let staged = try await AttachmentDraftStager.stage([sourceURL], in: testRoot)
        let stagedFile = try XCTUnwrap(staged.first)
        XCTAssertNotEqual(stagedFile.url, sourceURL)
        XCTAssertEqual(try Data(contentsOf: stagedFile.url), Data("Draft bytes".utf8))

        AttachmentDraftStager.clean(testRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFile.url.path))
    }

    func testFailedStagingBatchKeepsFilesFromAnEarlierBatch() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapDraftBatchTests-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapDraftBatchSources-\(UUID().uuidString)", isDirectory: true)
        let validURL = sourceRoot.appendingPathComponent("valid.txt")
        let missingURL = sourceRoot.appendingPathComponent("missing.txt")
        defer {
            AttachmentDraftStager.clean(testRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("Keep this".utf8).write(to: validURL)

        let firstBatch = try await AttachmentDraftStager.stage([validURL], in: testRoot)
        let keptURL = try XCTUnwrap(firstBatch.first?.url)
        do {
            _ = try await AttachmentDraftStager.stage([missingURL], in: testRoot)
            XCTFail("A missing file should fail staging.")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: keptURL), Data("Keep this".utf8))
    }

    func testAttachmentDraftStagingRejectsSymbolicLinks() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapDraftLinkTests-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapDraftLinkSources-\(UUID().uuidString)", isDirectory: true)
        let targetURL = sourceRoot.appendingPathComponent("target.txt")
        let linkURL = sourceRoot.appendingPathComponent("link.txt")
        defer {
            AttachmentDraftStager.clean(testRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("Outside bytes".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        do {
            _ = try await AttachmentDraftStager.stage([linkURL], in: testRoot)
            XCTFail("A symbolic link should not become an attachment draft.")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .attachmentCopyFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: testRoot.path))
    }

    func testSearchFiltersBulkDoneAndUndoStayAboveTheLibrarySeam() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        await model.load()

        let createdAlpha = await model.createSnip(content: "Alpha note", in: SnipList.inboxID)
        XCTAssertTrue(createdAlpha)
        let alphaID = try XCTUnwrap(model.selectedSnipID)
        let createdBeta = await model.createSnip(content: "Beta task", in: SnipList.inboxID)
        XCTAssertTrue(createdBeta)
        let betaID = try XCTUnwrap(model.selectedSnipID)

        model.searchText = "alpha"
        XCTAssertEqual(model.visibleSnips.map(\.id), [alphaID])
        model.searchText = ""
        model.selectedSnipIDs = [alphaID, betaID]
        let markedDone = await model.setSelectionDone(true)
        XCTAssertTrue(markedDone)
        model.completionFilter = .done
        XCTAssertEqual(Set(model.visibleSnips.map(\.id)), [alphaID, betaID])

        _ = try await library.perform(
            .add(
                content: "Unrelated write",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 500)
            ),
            sortedBy: .manual
        )
        let undone = await model.undo()
        XCTAssertTrue(undone)
        XCTAssertTrue(model.snips.filter { $0.id == alphaID || $0.id == betaID }.allSatisfy { !$0.isDone })
        XCTAssertTrue(model.snips.contains(where: { $0.content == "Unrelated write" }))
    }

    func testManualReorderAndBulkListMoveUseNormalRepositoryCommands() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        await model.load()
        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let workID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)
        model.selectedListID = SnipList.inboxID
        let createdOne = await model.createSnip(content: "One", in: SnipList.inboxID)
        XCTAssertTrue(createdOne)
        let oneID = try XCTUnwrap(model.selectedSnipID)
        let createdTwo = await model.createSnip(content: "Two", in: SnipList.inboxID)
        XCTAssertTrue(createdTwo)
        let twoID = try XCTUnwrap(model.selectedSnipID)

        model.sortMode = .manual
        let reordered = await model.placeVisibleSnips([oneID, twoID])
        XCTAssertTrue(reordered)
        XCTAssertEqual(model.visibleSnips.map(\.id), [oneID, twoID])
        model.selectedSnipIDs = [oneID, twoID]
        let moved = await model.moveSelection(to: workID)
        XCTAssertTrue(moved)
        XCTAssertEqual(model.snips.filter { $0.listID == workID }.map(\.id), [oneID, twoID])

        let undone = await model.undo()
        XCTAssertTrue(undone)
        XCTAssertEqual(model.visibleSnips.map(\.id), [oneID, twoID])
    }

    func testUndoDropsAnEntryWhenItsAffectedSnipChanged() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        await model.load()
        let created = await model.createSnip(content: "Original", in: SnipList.inboxID)
        XCTAssertTrue(created)
        let id = try XCTUnwrap(model.selectedSnipID)
        model.selectedSnipIDs = [id]
        let markedDone = await model.setSelectionDone(true)
        XCTAssertTrue(markedDone)
        let doneSnip = try XCTUnwrap(model.snips.first(where: { $0.id == id }))

        _ = try await library.perform(
            .update(
                id: id,
                content: "Changed elsewhere",
                attachmentURLs: nil,
                expectedUpdatedAt: doneSnip.updatedAt,
                now: Date(timeIntervalSince1970: 600)
            ),
            sortedBy: .manual
        )

        let undone = await model.undo()
        XCTAssertFalse(undone)
        XCTAssertEqual(model.undoTitle, "Undo New Snip")
        XCTAssertNotNil(model.errorMessage)
        let snapshot = await library.snapshot(sortedBy: .manual)
        XCTAssertEqual(snapshot.snips.first?.content, "Changed elsewhere")
    }

    func testSingleRowDoneAndUndoPreserveTheExistingSelection() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        await model.load()
        let madeFirst = await model.createSnip(content: "First", in: SnipList.inboxID)
        XCTAssertTrue(madeFirst)
        let firstID = try XCTUnwrap(model.selectedSnipID)
        let madeSecond = await model.createSnip(content: "Second", in: SnipList.inboxID)
        XCTAssertTrue(madeSecond)
        let secondID = try XCTUnwrap(model.selectedSnipID)
        model.selectedSnipIDs = [secondID]

        let marked = await model.toggleDone(id: firstID)
        XCTAssertTrue(marked)
        XCTAssertEqual(model.selectedSnipIDs, [secondID])

        let undone = await model.undo()
        XCTAssertTrue(undone)
        XCTAssertEqual(model.selectedSnipIDs, [secondID])
        XCTAssertEqual(model.snips.first(where: { $0.id == firstID })?.isDone, false)
    }

    func testOverlappingMutationsRunOneAtATimeAndBuildIndependentUndoEntries() async {
        let library = ModelTestLibrary(commandDelay: .milliseconds(80))
        let model = IOSAppModel(library: library)

        async let first = model.createSnip(content: "First", in: SnipList.inboxID)
        async let second = model.createSnip(content: "Second", in: SnipList.inboxID)
        let results = await (first, second)

        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        let maximumConcurrentCommands = await library.maximumConcurrentCommands()
        XCTAssertEqual(maximumConcurrentCommands, 1)
        XCTAssertEqual(model.snips.count, 2)

        let firstUndo = await model.undo()
        XCTAssertTrue(firstUndo)
        XCTAssertEqual(model.snips.count, 1)
        let secondUndo = await model.undo()
        XCTAssertTrue(secondUndo)
        XCTAssertTrue(model.snips.isEmpty)
    }

    func testUndoNewListRefusesToMoveASnipAddedElsewhere() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let workID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)

        _ = try await library.perform(
            .add(
                content: "Added elsewhere",
                origin: .quickEntry,
                source: nil,
                listID: workID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .manual
        )

        let undone = await model.undo()
        XCTAssertFalse(undone)
        let snapshot = await library.snapshot(sortedBy: .manual)
        XCTAssertTrue(snapshot.lists.contains(where: { $0.id == workID }))
        XCTAssertEqual(snapshot.snips.first?.listID, workID)
    }

    func testUndoDeletedSnipRefusesToRestoreIntoAListDeletedElsewhere() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let workID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)
        let createdSnip = await model.createSnip(content: "Removed", in: workID)
        XCTAssertTrue(createdSnip)
        let snipID = try XCTUnwrap(model.selectedSnipID)
        let deletedSnip = await model.deleteSnip(id: snipID)
        XCTAssertTrue(deletedSnip)

        _ = try await library.perform(.deleteList(id: workID), sortedBy: .manual)

        let undone = await model.undo()
        XCTAssertFalse(undone)
        let snapshot = await library.snapshot(sortedBy: .manual)
        XCTAssertFalse(snapshot.snips.contains(where: { $0.id == snipID }))
        XCTAssertFalse(snapshot.lists.contains(where: { $0.id == workID }))
    }

    func testUndoRenameDropsStaleEntryWhenTheOldNameWasTakenElsewhere() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let work = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" }))
        let renamedList = await model.renameList(work, name: "Focus")
        XCTAssertTrue(renamedList)
        _ = try await library.perform(
            .createList(name: "Work", systemImage: "list.bullet"),
            sortedBy: .manual
        )

        let undone = await model.undo()

        XCTAssertFalse(undone)
        XCTAssertEqual(model.undoTitle, "Undo New List")
        XCTAssertNotNil(model.errorMessage)
    }

    func testUndoDeletedListDropsStaleEntryWhenItsNameWasTakenElsewhere() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let work = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" }))
        let deletedList = await model.deleteList(id: work.id)
        XCTAssertTrue(deletedList)
        _ = try await library.perform(
            .createList(name: "Work", systemImage: "list.bullet"),
            sortedBy: .manual
        )

        let undone = await model.undo()

        XCTAssertFalse(undone)
        XCTAssertEqual(model.undoTitle, "Undo New List")
        XCTAssertNotNil(model.errorMessage)
    }

    func testTargetCannotCompileAppKit() {
        #if canImport(AppKit)
        XCTFail("The universal iOS target must not compile AppKit.")
        #endif
    }

}

private func testAttachment(id: UUID, fileName: String) throws -> SnipAttachment {
    let json = """
    {
      "id": "\(id.uuidString)",
      "fileName": "\(fileName)",
      "relativePath": "\(id.uuidString)/\(fileName)",
      "contentType": "public.text",
      "byteCount": 1
    }
    """
    return try JSONDecoder().decode(SnipAttachment.self, from: Data(json.utf8))
}

private actor ModelTestLibrary: SnipLibrary {
    private var snips: [Snip] = []
    private var lists: [SnipList] = [.inbox]
    private(set) var lastAddedAttachmentURLs: [URL] = []
    private(set) var lastAttachmentEdit: (snipID: UUID, content: String, edits: [SnipAttachmentEdit])?
    private var attachmentPruneCalls = 0
    private var attachmentRetentionCalls: [Set<UUID>] = []
    private let commandDelay: Duration?
    private var activeCommandCount = 0
    private var maximumActiveCommandCount = 0

    init(commandDelay: Duration? = nil) {
        self.commandDelay = commandDelay
    }

    func addedAttachmentURLs() -> [URL] {
        lastAddedAttachmentURLs
    }

    func pruneCalls() -> Int {
        attachmentPruneCalls
    }

    func retentionCalls() -> [Set<UUID>] {
        attachmentRetentionCalls
    }

    func snapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        makeSnapshot(sortMode: sortMode)
    }

    func perform(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate {
        activeCommandCount += 1
        maximumActiveCommandCount = max(maximumActiveCommandCount, activeCommandCount)
        defer { activeCommandCount -= 1 }
        if let commandDelay { try? await Task.sleep(for: commandDelay) }
        let outcome = try apply(command)
        return SnipLibraryUpdate(snapshot: makeSnapshot(sortMode: sortMode), outcome: outcome)
    }

    func maximumConcurrentCommands() -> Int {
        maximumActiveCommandCount
    }

    private func apply(_ command: SnipLibraryCommand) throws -> SnipLibraryOutcome {
        let outcome: SnipLibraryOutcome
        switch command {
        case .add(
            let content, let origin, let source, let listID, let attachmentURLs, let requestID,
            let now
        ):
            lastAddedAttachmentURLs = attachmentURLs
            let snip = Snip(
                requestID: requestID,
                createdAt: now,
                content: content,
                origin: origin,
                source: source,
                listID: listID,
                manualPosition: nextTopPosition(in: listID)
            )
            snips.append(snip)
            outcome = .add(.added(snip.id))
        case .update(let id, let content, _, _, let now):
            guard let index = snips.firstIndex(where: { $0.id == id }) else {
                throw SnipLibraryError.snipNotFound
            }
            snips[index].content = content
            snips[index].updatedAt = now
            outcome = .none
        case .editAttachments(let snipID, let content, let edits, _, let now):
            guard let index = snips.firstIndex(where: { $0.id == snipID }) else {
                throw SnipLibraryError.snipNotFound
            }
            lastAttachmentEdit = (snipID, content, edits)
            snips[index].content = content
            snips[index].updatedAt = now
            outcome = .none
        case .delete(let ids):
            snips.removeAll { ids.contains($0.id) }
            outcome = .none
        case .pruneAttachments(let retainedIDs):
            attachmentPruneCalls += 1
            attachmentRetentionCalls.append(retainedIDs)
            outcome = .none
        case .restore(let restored):
            let existing = Set(snips.map(\.id))
            snips.append(contentsOf: restored.filter { !existing.contains($0.id) })
            outcome = .none
        case .setDone(let ids, let done):
            for index in snips.indices where ids.contains(snips[index].id) {
                snips[index].isDone = done
                snips[index].updatedAt = Date()
            }
            outcome = .none
        case .place(let ids, let listID, let destinationID, let sortMode):
            let moving = Set(ids)
            var destination = Snip.sorted(
                snips.filter { $0.listID == listID && !moving.contains($0.id) },
                by: sortMode
            ).map(\.id)
            let insertion = destinationID.flatMap(destination.firstIndex) ?? destination.endIndex
            destination.insert(contentsOf: ids, at: insertion)
            let sourceLists = Set(snips.filter { moving.contains($0.id) }.map(\.listID))
            for index in snips.indices where moving.contains(snips[index].id) {
                snips[index].listID = listID
            }
            reindex(listID: listID, orderedIDs: destination)
            for sourceList in sourceLists where sourceList != listID { reindex(listID: sourceList) }
            outcome = .none
        case .moveChronologically(let ids, let listID):
            for index in snips.indices where ids.contains(snips[index].id) {
                snips[index].listID = listID
                snips[index].manualPosition = nextTopPosition(in: listID, excluding: Set(ids))
            }
            outcome = .none
        case .createList(let name, let systemImage):
            guard !lists.contains(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { throw SnipLibraryError.duplicateList }
            let list = SnipList(
                id: UUID(),
                name: name,
                systemImage: systemImage,
                position: lists.count
            )
            lists.append(list)
            outcome = .listCreated(list)
        case .restoreList(let list):
            guard !lists.contains(where: { $0.id == list.id }),
                !lists.contains(where: {
                    $0.name.caseInsensitiveCompare(list.name) == .orderedSame
                })
            else { throw SnipLibraryError.invalidList }
            for index in lists.indices where lists[index].position >= list.position {
                lists[index].position += 1
            }
            lists.append(list)
            outcome = .none
        case .updateList(let id, let name, let systemImage):
            guard let index = lists.firstIndex(where: { $0.id == id }) else {
                throw SnipLibraryError.invalidList
            }
            guard !lists.contains(where: {
                $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { throw SnipLibraryError.duplicateList }
            lists[index].name = name
            lists[index].systemImage = systemImage
            outcome = .none
        case .deleteList(let id):
            lists.removeAll { $0.id == id }
            for index in snips.indices where snips[index].listID == id {
                snips[index].listID = SnipList.inboxID
            }
            for index in lists.indices { lists[index].position = index }
            outcome = .none
        case .batch(let commands):
            var last: SnipLibraryOutcome = .none
            for command in commands {
                let next = try apply(command)
                if next != .none { last = next }
            }
            outcome = last
        case .guarded(let expectation, let command):
            let snipsByID = Dictionary(uniqueKeysWithValues: snips.map { ($0.id, $0) })
            let listsByID = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0) })
            guard expectation.expectedSnips.allSatisfy({ snipsByID[$0.id] == $0 }),
                expectation.absentSnipIDs.allSatisfy({ snipsByID[$0] == nil }),
                expectation.expectedLists.allSatisfy({ listsByID[$0.id] == $0 }),
                expectation.absentListIDs.allSatisfy({ listsByID[$0] == nil }),
                expectation.requiredListIDs.allSatisfy({ listsByID[$0] != nil }),
                expectation.expectedListMemberships.allSatisfy({ listID, expectedIDs in
                    listsByID[listID] != nil
                        && Set(snips.lazy.filter { $0.listID == listID }.map(\.id)) == expectedIDs
                })
            else { throw SnipLibraryError.snipChanged }
            outcome = try apply(command)
        default:
            outcome = .none
        }
        return outcome
    }

    private func makeSnapshot(sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        SnipLibrarySnapshot(
            snips: lists.sorted { $0.position < $1.position }.flatMap { list in
                Snip.sorted(snips.filter { $0.listID == list.id }, by: sortMode)
            },
            lists: lists.sorted { $0.position < $1.position }
        )
    }

    private func nextTopPosition(in listID: UUID, excluding: Set<UUID> = []) -> Int64 {
        (snips.filter { $0.listID == listID && !excluding.contains($0.id) }
            .map(\.manualPosition).min() ?? 1) - 1
    }

    private func reindex(listID: UUID, orderedIDs: [UUID]? = nil) {
        let ids = orderedIDs ?? Snip.sorted(
            snips.filter { $0.listID == listID },
            by: .manual
        ).map(\.id)
        for (position, id) in ids.enumerated() {
            guard let index = snips.firstIndex(where: { $0.id == id }) else { continue }
            snips[index].manualPosition = Int64(position)
        }
    }
}
