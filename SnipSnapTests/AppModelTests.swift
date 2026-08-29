import XCTest
import SnipSnapCore
import Foundation
import AppKit
@testable import SnipSnap
@testable import SnipSnapPersistence

final class AppModelTests: StoreBackedTestCase {
    @MainActor
    func testMacAccountNoticeInvokesHandlerAndHidesAfterRemove() async {
        let handler = MacAppleAccountCacheHandlerProbe()
        let model = AppleAccountNoticeModel(notice: .accountChanged, handler: handler)
        XCTAssertEqual(model.notice, .accountChanged)

        await model.resolve(.remove)

        XCTAssertNil(model.notice)
        let choices = await handler.choices()
        XCTAssertEqual(choices, [.remove])
    }

    @MainActor
    func testMacLocalOnlyAssemblyHidesNoticeWithoutAHandler() {
        let model = AppleAccountNoticeModel(notice: .signedOut, handler: nil)
        XCTAssertNil(model.notice)
    }

    @MainActor
    func testMacPausedNoticeRendersWithoutCacheChoices() {
        let model = AppleAccountNoticeModel(
            notice: .paused,
            handler: MacAppleAccountCacheHandlerProbe()
        )

        XCTAssertEqual(model.title, "iCloud Sync Paused")
        XCTAssertTrue(model.message.contains("still on this Mac"))
        XCTAssertFalse(model.showsResolutionActions)
    }

    @MainActor
    func testMacAccountNoticeRefreshReadsTheProductionHandlerSeam() async {
        let handler = MacAppleAccountCacheHandlerProbe(notices: [.signedOut, nil])
        let model = AppleAccountNoticeModel(handler: handler)

        await model.refresh()
        XCTAssertEqual(model.notice, .signedOut)

        await model.resolve(.keepLocalCopy)
        XCTAssertNil(model.notice)
        let choices = await handler.choices()
        let refreshCount = await handler.refreshCount()
        XCTAssertEqual(choices, [.keepLocalCopy])
        XCTAssertEqual(refreshCount, 2)
    }

    @MainActor
    func testMacMainPanelReceivesNeedsAttentionModel() throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "Snip SnapAccountNoticePanelTests-\(UUID().uuidString)")
        )
        let appModel = AppModel(
            library: try JSONSnipLibrary(fileURL: try storeURL()),
            defaults: defaults
        )
        let settings = ShortcutSettings(defaults: defaults)
        let noticeModel = AppleAccountNoticeModel(
            notice: .accountChanged,
            handler: MacAppleAccountCacheHandlerProbe()
        )

        let view = ContentView(
            coordinator: AppCoordinator(model: appModel, shortcutSettings: settings),
            fileDropController: PanelFileDropController(),
            snipDragSourceController: SnipDragSourceController(),
            accountNoticeModel: noticeModel
        )

        XCTAssertTrue(view.showsAccountNoticeInMainPanel)
        XCTAssertEqual(noticeModel.title, "Apple Account Changed")
        XCTAssertTrue(noticeModel.showsResolutionActions)
    }

    private actor InMemorySnipLibrary: SnipLibrary {
        private var snips: [Snip]
        private(set) var addedContents: [String] = []
        private(set) var snapshotCallCount = 0

        init(snips: [Snip]) {
            self.snips = snips
        }

        func snapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
            snapshotCallCount += 1
            return makeSnapshot(sortedBy: sortMode)
        }

        private func makeSnapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
            SnipLibrarySnapshot(snips: Snip.sorted(snips, by: sortMode), lists: [.inbox])
        }

        func perform(
            _ command: SnipLibraryCommand,
            sortedBy sortMode: SnipSortMode
        ) throws -> SnipLibraryUpdate {
            let outcome: SnipLibraryOutcome
            switch command {
            case let .add(content, origin, source, listID, _, requestID, now):
                let snip = Snip(
                    requestID: requestID,
                    createdAt: now,
                    content: content,
                    origin: origin,
                    source: source,
                    listID: listID
                )
                snips.append(snip)
                addedContents.append(content)
                outcome = .add(.added(snip.id))
            case .pruneAttachments:
                outcome = .none
            default:
                throw SnipLibraryError.storeUnavailable
            }
            return SnipLibraryUpdate(snapshot: makeSnapshot(sortedBy: sortMode), outcome: outcome)
        }
    }

    @MainActor
    private func defaults() -> UserDefaults {
        let suite = "Snip SnapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor
    func testAppModelAcceptsAnInMemoryLibraryWithoutProductionStorage() async {
        let saved = Snip(content: "Already here", origin: .quickEntry)
        let library = InMemorySnipLibrary(snips: [saved])
        let model = AppModel(library: library, defaults: defaults())
        await model.reload()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(model.snips.map(\.id), [saved.id])
        let snapshotCallsBeforeAdd = await library.snapshotCallCount
        let didAdd = await model.add(content: "New", origin: .quickEntry)
        let addedContents = await library.addedContents
        let snapshotCallsAfterAdd = await library.snapshotCallCount
        XCTAssertTrue(didAdd)
        XCTAssertEqual(addedContents, ["New"])
        XCTAssertEqual(snapshotCallsAfterAdd, snapshotCallsBeforeAdd)
        XCTAssertEqual(Set(model.snips.map(\.content)), ["Already here", "New"])
    }

    @MainActor
    func testCancelledScreenCaptureRemovesTheTemporaryFile() throws {
        let store = ComposerDraftStore(defaults: defaults(), textDefaultsKey: "capture-draft")
        let url = store.stageScreenCapture()
        try Data("partial".utf8).write(to: url)

        store.finishScreenCapture(url, in: SnipList.inboxID, succeeded: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.draft(for: SnipList.inboxID).attachments.isEmpty)
    }

    @MainActor
    func testCompletedScreenCaptureJoinsTheDraftAndClearsWithIt() throws {
        let store = ComposerDraftStore(defaults: defaults(), textDefaultsKey: "capture-draft")
        let url = store.stageScreenCapture()
        try Data("image".utf8).write(to: url)

        store.finishScreenCapture(url, in: SnipList.inboxID, succeeded: true)
        XCTAssertEqual(store.draft(for: SnipList.inboxID).attachments, [url])

        store.clear(listID: SnipList.inboxID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testAppearanceDefaultsToSystemAndPersistsAChoice() throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let defaults = defaults()
        var model: AppModel? = AppModel(library: repository, defaults: defaults)

        XCTAssertEqual(model?.appearance, .system)

        model?.setAppearance(.dark)
        XCTAssertEqual(defaults.string(forKey: AppModel.appearanceDefaultsKey), "dark")

        model = AppModel(library: repository, defaults: defaults)
        XCTAssertEqual(model?.appearance, .dark)
    }

    @MainActor
    func testToggleDoneItemChangesOnlyThatItemAndKeepsSelection() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let firstResult = try await repository.add(content: "First", origin: .quickEntry)
        let secondResult = try await repository.add(content: "Second", origin: .quickEntry)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        let model = AppModel(library: repository)
        await model.reload()
        model.selection = [first.id, second.id]

        await model.toggleDoneNow(id: first.id)

        XCTAssertEqual(model.selection, [first.id, second.id])
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == first.id }).isDone)
        XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == second.id }).isDone)
    }

    @MainActor
    func testRapidDoneTogglesApplyInOrder() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let added = try await repository.add(content: "Snip", origin: .quickEntry)
        let snip = try XCTUnwrap(added)
        let model = AppModel(library: repository)
        await model.reload()

        async let first: Void = model.toggleDoneNow(id: snip.id)
        async let second: Void = model.toggleDoneNow(id: snip.id)
        _ = await (first, second)

        XCTAssertFalse(try XCTUnwrap(model.snips.first).isDone)
    }

    @MainActor
    func testSuccessfulExternalDropMarksEveryDraggedSnipDone() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let firstResult = try await repository.add(content: "First", origin: .quickEntry)
        let secondResult = try await repository.add(content: "Second", origin: .quickEntry)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        try await repository.setDone(ids: [second.id], done: true)
        let model = AppModel(library: repository)
        await model.reload()

        await model.markDoneAfterExternalDropNow(ids: [first.id, second.id])

        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == first.id }).isDone)
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == second.id }).isDone)
    }

    @MainActor
    func testAppModelUndoDeleteRestoresTheFullSelection() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let addedFirst = try await repository.add(content: "First", origin: .quickEntry)
        let addedSecond = try await repository.add(content: "Second", origin: .quickEntry)
        let first = try XCTUnwrap(addedFirst)
        let second = try XCTUnwrap(addedSecond)
        let model = AppModel(library: repository)
        await model.reload()
        model.selection = [first.id, second.id]

        await model.deleteSelectionNow()
        XCTAssertTrue(model.snips.isEmpty)
        XCTAssertTrue(model.canUndo)

        await model.undoNow()
        XCTAssertEqual(Set(model.snips.map(\.id)), [first.id, second.id])
        XCTAssertEqual(model.selection, [first.id, second.id])
        XCTAssertFalse(model.canUndo)
    }

    @MainActor
    func testTwoRapidUndosConsumeOneOperationSafely() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let added = try await repository.add(content: "Delete me", origin: .quickEntry)
        let snip = try XCTUnwrap(added)
        let model = AppModel(library: repository)
        await model.reload()
        model.selection = [snip.id]
        await model.deleteSelectionNow()

        async let first: Void = model.undoNow()
        async let second: Void = model.undoNow()
        _ = await (first, second)

        XCTAssertEqual(model.snips.map(\.id), [snip.id])
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canRedo)
    }

    @MainActor
    func testAppModelUndoMergeRestoresTheOriginalItems() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let addedFirst = try await repository.add(content: "First", origin: .quickEntry)
        let addedSecond = try await repository.add(content: "Second", origin: .quickEntry)
        let first = try XCTUnwrap(addedFirst)
        let second = try XCTUnwrap(addedSecond)
        let model = AppModel(library: repository)
        await model.reload()
        model.selection = [first.id, second.id]

        await model.mergeSelectionNow()
        XCTAssertEqual(model.snips.count, 1)
        XCTAssertEqual(model.undoTitle, "Undo Merge")

        await model.undoNow()
        XCTAssertEqual(Set(model.snips.map(\.id)), [first.id, second.id])
        XCTAssertEqual(model.selection, [first.id, second.id])
        XCTAssertFalse(model.canUndo)
    }

    @MainActor
    func testEditingAMergeClearsTheStaleMergeUndo() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let addedFirst = try await repository.add(content: "First", origin: .quickEntry)
        let addedSecond = try await repository.add(content: "Second", origin: .quickEntry)
        let first = try XCTUnwrap(addedFirst)
        let second = try XCTUnwrap(addedSecond)
        let model = AppModel(library: repository)
        await model.reload()
        model.selection = [first.id, second.id]

        await model.mergeSelectionNow()
        let merged = try XCTUnwrap(model.snips.first)
        XCTAssertTrue(model.canUndo)

        let saved = await model.update(id: merged.id, content: "Edited merge")
        XCTAssertTrue(saved)
        XCTAssertFalse(model.canUndo)
        await model.undoNow()

        XCTAssertEqual(model.snips.map(\.content), ["Edited merge"])
    }

    @MainActor
    func testAddResultKeepsStoreFailureDistinctFromDuplicate() async {
        let model = AppModel(library: JSONSnipLibrary.unavailable())

        let result = await model.addResult(content: "Keep me", origin: .selection)

        guard case .failure(let error) = result else {
            return XCTFail("An unavailable store must return a failure.")
        }
        XCTAssertEqual(error as? SnipLibraryError, .storeUnavailable)
    }

    @MainActor
    func testAddResultReturnsTheCreatedSnipIdentity() async throws {
        let model = AppModel(library: try JSONSnipLibrary(fileURL: storeURL()))

        let result = await model.addResult(content: "Created", origin: .quickEntry)

        guard case .success(.added(let id)) = result else {
            return XCTFail("A new snip must return its own identity.")
        }
        XCTAssertEqual(model.snips.first?.id, id)
        XCTAssertEqual(model.latestAddedSnipID, id)
    }

    @MainActor
    func testDetachedEditCannotOverwriteANewerEdit() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let addedOriginal = try await repository.add(content: "Original", origin: .quickEntry)
        let original = try XCTUnwrap(addedOriginal)
        let model = AppModel(library: repository)
        await model.reload()

        let savedNewerEdit = await model.update(id: original.id, content: "Newer inline edit")
        let savedStaleEdit = await model.update(
            id: original.id,
            content: "Stale detached edit",
            expectedUpdatedAt: original.updatedAt
        )
        XCTAssertTrue(savedNewerEdit)
        XCTAssertFalse(savedStaleEdit)

        let saved = try XCTUnwrap(model.snips.first(where: { $0.id == original.id }))
        XCTAssertEqual(saved.content, "Newer inline edit")
        XCTAssertEqual(model.presentedError, SnipLibraryError.snipChanged.localizedDescription)
    }

    @MainActor
    func testAppModelDoesNotSelectNewlyAddedInlineItem() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: repository)

        let saved = await model.add(
            content: "Inline focus handoff",
            origin: .quickEntry
        )

        XCTAssertTrue(saved)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.latestAddedSnipID, model.snips.first?.id)
    }

    @MainActor
    func testSortModePersistsAndRestoresManualOrder() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let olderResult = try await repository.add(
            content: "Older", origin: .quickEntry, now: Date(timeIntervalSince1970: 100)
        )
        let newerResult = try await repository.add(
            content: "Newer", origin: .quickEntry, now: Date(timeIntervalSince1970: 200)
        )
        let older = try XCTUnwrap(olderResult)
        let newer = try XCTUnwrap(newerResult)
        let settings = defaults()
        let model = AppModel(library: repository, defaults: settings)
        await model.reload()

        let didMove = await model.move(ids: [older.id], to: SnipList.inboxID, before: newer.id)
        XCTAssertTrue(didMove)
        XCTAssertEqual(model.sortMode, .manual)
        XCTAssertEqual(model.snips.map(\.content), ["Older", "Newer"])
        model.setSortMode(.chronological)
        XCTAssertEqual(model.snips.map(\.content), ["Newer", "Older"])
        model.setSortMode(.manual)
        XCTAssertEqual(model.snips.map(\.content), ["Older", "Newer"])

        let reopenedModel = AppModel(library: repository, defaults: settings)
        await reopenedModel.reload()
        XCTAssertEqual(reopenedModel.sortMode, .manual)
        XCTAssertEqual(reopenedModel.snips.map(\.content), ["Older", "Newer"])
    }

    @MainActor
    func testRenamedDefaultsKeepListStateAndDrafts() async throws {
        let settings = defaults()
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let list = try await repository.createList(name: "Review", systemImage: "star")
        let listID = list.id
        settings.set(SnipSortMode.manual.rawValue, forKey: "clipSortMode")
        settings.set(listID.uuidString, forKey: "activeSectionID")
        settings.set([listID.uuidString: "Saved draft"], forKey: "sectionDrafts")

        let model = AppModel(library: repository, defaults: settings)
        await model.reload()

        XCTAssertEqual(model.sortMode, .manual)
        XCTAssertEqual(model.activeListID, listID)
        XCTAssertEqual(model.composerDraft(for: listID).text, "Saved draft")
        XCTAssertEqual(settings.string(forKey: AppModel.sortModeDefaultsKey), "manual")
        XCTAssertEqual(settings.string(forKey: AppModel.activeListDefaultsKey), listID.uuidString)
        XCTAssertNotNil(settings.dictionary(forKey: AppModel.listDraftsDefaultsKey))
    }

    @MainActor
    func testMoveKeepsEditorTokenAndSupportsMultiStepUndoRedo() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let firstResult = try await repository.add(content: "First", origin: .quickEntry)
        let secondResult = try await repository.add(content: "Second", origin: .quickEntry)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        let review = try await repository.createList(name: "Review", systemImage: "star")
        let model = AppModel(library: repository, defaults: defaults())
        await model.reload()
        let token = first.updatedAt

        let movedFirst = await model.moveChronologically(ids: [first.id], to: review.id)
        let movedSecond = await model.moveChronologically(ids: [second.id], to: review.id)
        XCTAssertTrue(movedFirst)
        XCTAssertTrue(movedSecond)
        XCTAssertEqual(model.snips.first { $0.id == first.id }?.updatedAt, token)
        XCTAssertTrue(model.canUndo)

        await model.undoNow()
        XCTAssertEqual(model.snips.first { $0.id == second.id }?.listID, SnipList.inboxID)
        await model.undoNow()
        XCTAssertEqual(model.snips.first { $0.id == first.id }?.listID, SnipList.inboxID)
        XCTAssertTrue(model.canRedo)

        await model.redoNow()
        await model.redoNow()
        XCTAssertEqual(Set(model.snips.filter { $0.listID == review.id }.map(\.id)), [first.id, second.id])
        XCTAssertFalse(model.canRedo)
    }

    @MainActor
    func testMoveUpUsesManualOrderAndCanUndo() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let firstResult = try await repository.add(content: "First", origin: .quickEntry)
        let secondResult = try await repository.add(content: "Second", origin: .quickEntry)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        let model = AppModel(library: repository, defaults: defaults())
        await model.reload()
        model.setSortMode(.manual)
        XCTAssertEqual(model.snips.map(\.id), [second.id, first.id])
        model.selection = [first.id]

        await model.moveSelectionNow(by: -1)
        XCTAssertEqual(model.snips.map(\.id), [first.id, second.id])
        await model.undoNow()
        XCTAssertEqual(model.snips.map(\.id), [second.id, first.id])
    }

    @MainActor
    func testExactMoveFromChronologicalUsesVisibleOrderAsManualSeed() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let oldResult = try await repository.add(
            content: "Old", origin: .quickEntry, now: Date(timeIntervalSince1970: 100)
        )
        let middleResult = try await repository.add(
            content: "Middle", origin: .quickEntry, now: Date(timeIntervalSince1970: 200)
        )
        let newResult = try await repository.add(
            content: "New", origin: .quickEntry, now: Date(timeIntervalSince1970: 300)
        )
        let old = try XCTUnwrap(oldResult)
        let middle = try XCTUnwrap(middleResult)
        let new = try XCTUnwrap(newResult)
        try await repository.place(
            ids: [old.id, new.id, middle.id],
            in: SnipList.inboxID,
            before: nil
        )
        let model = AppModel(library: repository, defaults: defaults())
        await model.reload()
        XCTAssertEqual(model.snips.map(\.id), [new.id, middle.id, old.id])

        let moved = await model.move(
            ids: [middle.id],
            to: SnipList.inboxID,
            before: new.id
        )

        XCTAssertTrue(moved)
        XCTAssertEqual(model.sortMode, .manual)
        XCTAssertEqual(model.snips.map(\.id), [middle.id, new.id, old.id])

        await model.undoNow()
        XCTAssertEqual(model.sortMode, .chronological)
        XCTAssertEqual(model.snips.map(\.id), [new.id, middle.id, old.id])

        await model.redoNow()
        XCTAssertEqual(model.sortMode, .manual)
        XCTAssertEqual(model.snips.map(\.id), [middle.id, new.id, old.id])
    }

    @MainActor
    func testDropMoveCanPreserveSelectionThroughUndoAndRedo() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let movedResult = try await repository.add(content: "Moved", origin: .quickEntry)
        let selectedResult = try await repository.add(content: "Selected", origin: .quickEntry)
        let moved = try XCTUnwrap(movedResult)
        let selected = try XCTUnwrap(selectedResult)
        let review = try await repository.createList(name: "Review", systemImage: "star")
        let model = AppModel(library: repository, defaults: defaults())
        await model.reload()
        model.selection = [selected.id]

        let didMove = await model.moveChronologically(
            ids: [moved.id],
            to: review.id,
            selectionAfterMove: model.selection
        )

        XCTAssertTrue(didMove)
        XCTAssertEqual(model.selection, [selected.id])
        await model.undoNow()
        XCTAssertEqual(model.selection, [selected.id])
        await model.redoNow()
        XCTAssertEqual(model.selection, [selected.id])
        XCTAssertEqual(model.snips.first { $0.id == moved.id }?.listID, review.id)
    }

    @MainActor
    func testMoveUpFromChronologicalUsesVisibleOrder() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let oldResult = try await repository.add(
            content: "Old", origin: .quickEntry, now: Date(timeIntervalSince1970: 100)
        )
        let middleResult = try await repository.add(
            content: "Middle", origin: .quickEntry, now: Date(timeIntervalSince1970: 200)
        )
        let newResult = try await repository.add(
            content: "New", origin: .quickEntry, now: Date(timeIntervalSince1970: 300)
        )
        let old = try XCTUnwrap(oldResult)
        let middle = try XCTUnwrap(middleResult)
        let new = try XCTUnwrap(newResult)
        try await repository.place(
            ids: [old.id, new.id, middle.id],
            in: SnipList.inboxID,
            before: nil
        )
        let model = AppModel(library: repository, defaults: defaults())
        await model.reload()
        model.selection = [middle.id]

        await model.moveSelectionNow(by: -1)

        XCTAssertEqual(model.sortMode, .manual)
        XCTAssertEqual(model.snips.map(\.id), [middle.id, new.id, old.id])
    }

    @MainActor
    func testMoveUpDoesNothingWhileAFilterIsActive() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let firstResult = try await repository.add(content: "First", origin: .quickEntry)
        let secondResult = try await repository.add(content: "Second", origin: .quickEntry)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        let model = AppModel(library: repository, defaults: defaults())
        await model.reload()
        model.selection = [first.id]
        let originalIDs = model.snips.map(\.id)
        XCTAssertTrue(model.canReorder(ids: [first.id]))

        model.query = "First"
        XCTAssertFalse(model.canReorderSelection)
        XCTAssertFalse(model.canReorder(ids: [first.id]))
        await model.moveSelectionNow(by: -1)
        XCTAssertEqual(model.snips.map(\.id), originalIDs)
        XCTAssertEqual(model.sortMode, .chronological)

        model.query = ""
        model.completionFilter = .done
        XCTAssertFalse(model.canReorderSelection)
        XCTAssertFalse(model.canReorder(ids: [first.id]))
        await model.moveSelectionNow(by: -1)
        XCTAssertEqual(model.snips.map(\.id), originalIDs)
        XCTAssertEqual(model.sortMode, .chronological)
        XCTAssertEqual(Set(originalIDs), [first.id, second.id])
    }

    @MainActor
    func testCreatingListKeepsCurrentSelectionWhereItIs() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let addedSelection = try await repository.add(content: "Move me", origin: .quickEntry)
        let selected = try XCTUnwrap(addedSelection)
        _ = try await repository.add(content: "Leave me", origin: .quickEntry)
        let model = AppModel(library: repository, defaults: defaults())
        await model.reload()
        model.selection = [selected.id]

        let didCreate = await model.createList(name: "Agents", systemImage: "terminal.fill")
        XCTAssertTrue(didCreate)

        XCTAssertEqual(model.activeList.name, "Agents")
        XCTAssertEqual(model.snips.first { $0.id == selected.id }?.listID, SnipList.inboxID)
    }

    @MainActor
    func testCreatingListForMoveMovesTheCurrentSelection() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let addedSelection = try await repository.add(content: "Move me", origin: .quickEntry)
        let selected = try XCTUnwrap(addedSelection)
        _ = try await repository.add(content: "Leave me", origin: .quickEntry)
        let model = AppModel(library: repository, defaults: defaults())
        await model.reload()
        model.selection = [selected.id]

        let didCreate = await model.createList(
            name: "Agents",
            systemImage: "terminal.fill",
            movingIDs: model.selection
        )
        let activeListID = model.activeListID
        let activeListName = model.activeList.name
        let movedListID = model.snips.first { $0.id == selected.id }?.listID
        let selection = model.selection

        XCTAssertTrue(didCreate)
        XCTAssertEqual(activeListName, "Agents")
        XCTAssertEqual(movedListID, activeListID)
        XCTAssertEqual(selection, [selected.id])
    }

    @MainActor
    func testDeletingTheActiveListPersistsInboxAsActive() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let settings = defaults()
        let list = try await repository.createList(name: "Review", systemImage: "star")
        let model = AppModel(library: repository, defaults: settings)
        await model.reload()
        model.selectList(list)

        await model.deleteList(list)

        XCTAssertEqual(model.activeListID, SnipList.inboxID)
        XCTAssertEqual(
            settings.string(forKey: AppModel.activeListDefaultsKey),
            SnipList.inboxID.uuidString
        )
    }

    @MainActor
    func testSavingAClipboardFileWithAnImagePreviewCreatesOneAttachment() async throws {
        let url = try storeURL()
        let source = url.deletingLastPathComponent().appendingPathComponent("preview.png")
        try Data([1, 2, 3]).write(to: source)
        let entry = ClipboardEntry(
            sourceApplication: "Tests",
            items: [
                ClipboardPayloadItem(representations: [
                    ClipboardRepresentation(type: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data(source.absoluteString.utf8)),
                    ClipboardRepresentation(type: NSPasteboard.PasteboardType.png.rawValue, data: Data([4, 5, 6]))
                ])
            ]
        )
        let model = AppModel(library: try JSONSnipLibrary(fileURL: url), defaults: defaults())
        await model.reload()

        let saved = await model.saveClipboardEntry(entry)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.snips.first?.attachments.count, 1)
    }

    @MainActor
    func testAttachmentFilesSurviveUndoAndAreRemovedAfterHistoryClears() async throws {
        let url = try storeURL()
        let source = url.deletingLastPathComponent().appendingPathComponent("context.md")
        try Data("Context".utf8).write(to: source)
        let repository = try JSONSnipLibrary(fileURL: url)
        let addedItem = try await repository.add(
            content: "Attached",
            origin: .quickEntry,
            attachmentURLs: [source]
        )
        let snip = try XCTUnwrap(addedItem)
        let storedURL = repository.attachmentURL(for: try XCTUnwrap(snip.attachments.first))
        let model = AppModel(library: repository, defaults: defaults())
        await model.reload()
        model.selection = [snip.id]

        await model.deleteSelectionNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))
        await model.undoNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))

        model.selection = [snip.id]
        await model.deleteSelectionNow()
        let didAdd = await model.add(content: "Clears undo", origin: .quickEntry)
        XCTAssertTrue(didAdd)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
    }

    @MainActor
    func testEditingRetainsStoredAttachmentsWithoutCopyingThemAgain() async throws {
        let url = try storeURL()
        let source = url.deletingLastPathComponent().appendingPathComponent("note.md")
        try Data("Note".utf8).write(to: source)
        let repository = try JSONSnipLibrary(fileURL: url)
        let addedItem = try await repository.add(
            content: "Before",
            origin: .quickEntry,
            attachmentURLs: [source]
        )
        let snip = try XCTUnwrap(addedItem)
        let originalAttachment = try XCTUnwrap(snip.attachments.first)
        let model = AppModel(library: repository, defaults: defaults())
        await model.reload()

        let didUpdate = await model.update(
            id: snip.id,
            content: "After",
            attachmentURLs: [model.attachmentURL(for: originalAttachment)]
        )
        XCTAssertTrue(didUpdate)

        let saved = try XCTUnwrap(model.snips.first)
        XCTAssertEqual(saved.attachments, [originalAttachment])
        let directories = try FileManager.default.contentsOfDirectory(
            at: repository.attachmentRootURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(directories.count, 1)
    }

    @MainActor
    func testSelectingAListCanPreserveTheCurrentSelectionDuringDrag() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let addedItem = try await repository.add(content: "Snip", origin: .quickEntry)
        let snip = try XCTUnwrap(addedItem)
        let list = try await repository.createList(name: "Review", systemImage: "star")
        let model = AppModel(library: repository, defaults: defaults())
        await model.reload()
        model.selection = [snip.id]

        model.selectList(list, preservingSelection: true)

        XCTAssertEqual(model.activeListID, list.id)
        XCTAssertEqual(model.selection, [snip.id])
    }

    @MainActor
    func testComposerDraftKeepsNewAttachmentsWhenAnEarlierSaveFinishes() throws {
        let store = ComposerDraftStore(defaults: defaults(), textDefaultsKey: "drafts")
        let listID = UUID()
        let first = URL(fileURLWithPath: "/tmp/first.md")
        let second = URL(fileURLWithPath: "/tmp/second.md")
        store.setText("First draft", for: listID)
        store.add([first], to: listID)
        let snapshot = store.beginSave(listID: listID)

        store.setText("New draft", for: listID)
        store.add([second], to: listID)
        store.finishSave(snapshot, saved: true)

        XCTAssertEqual(
            store.draft(for: listID),
            ComposerDraft(text: "New draft", attachments: [second])
        )
    }

    @MainActor
    func testComposerDraftFlushPersistsTheCurrentInMemoryText() throws {
        let defaults = defaults()
        let listID = UUID()
        let firstStore = ComposerDraftStore(defaults: defaults, textDefaultsKey: "drafts")
        firstStore.setText("Current draft", for: listID)

        firstStore.flushText()

        let reopenedStore = ComposerDraftStore(defaults: defaults, textDefaultsKey: "drafts")
        XCTAssertEqual(reopenedStore.draft(for: listID).text, "Current draft")
    }

    @MainActor
    func testComposerDraftRetainsTemporaryFilesUntilAnActiveSaveFinishes() throws {
        let directory = try storeURL().deletingLastPathComponent()
        let temporary = directory.appendingPathComponent("capture.png")
        try Data([1, 2, 3]).write(to: temporary)
        let store = ComposerDraftStore(defaults: defaults(), textDefaultsKey: "drafts")
        let listID = UUID()
        store.addTemporary(temporary, to: listID)
        let snapshot = store.beginSave(listID: listID)

        store.clear(listID: listID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))

        store.finishSave(snapshot, saved: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }
}

private actor MacAppleAccountCacheHandlerProbe: AppleAccountCacheHandling {
    private var received: [AppleAccountCacheChoice] = []
    private var notices: [AppleAccountNotice?]
    private var noticeReads = 0

    init(notices: [AppleAccountNotice?] = []) {
        self.notices = notices
    }

    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? {
        defer { noticeReads += 1 }
        return notices.indices.contains(noticeReads) ? notices[noticeReads] : nil
    }

    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {
        received.append(choice)
    }

    func choices() -> [AppleAccountCacheChoice] { received }
    func refreshCount() -> Int { noticeReads }
}
