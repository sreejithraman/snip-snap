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
final class IOSListModelTests: IOSModelTestCase {
    func testPageSelectionKeepsTheLastListWhileClipboardIsActive() async throws {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        let created = await model.createList(name: "Work")
        XCTAssertTrue(created)
        let workID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)
        XCTAssertEqual(model.pages, [.clipboard, .list(SnipList.inboxID), .list(workID)])
        XCTAssertEqual(model.selectedPage, .list(workID))

        model.selectedSnipID = UUID()
        model.selectedSnipIDs = [UUID()]
        model.selectPage(.clipboard)
        XCTAssertEqual(model.selectedPage, .clipboard)
        XCTAssertEqual(model.lastSelectedListID, workID)
        XCTAssertNil(model.selectedSnipID)
        XCTAssertTrue(model.selectedSnipIDs.isEmpty)

        model.selectPage(.list(SnipList.inboxID))
        XCTAssertEqual(model.selectedPage, .list(SnipList.inboxID))
        XCTAssertEqual(model.lastSelectedListID, SnipList.inboxID)
    }

    func testDeletingTheLastListKeepsTheSelectedPageValid() async throws {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        let created = await model.createList(name: "Work")
        XCTAssertTrue(created)
        let workID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)

        let deleted = await model.deleteList(id: workID)
        XCTAssertTrue(deleted)
        XCTAssertEqual(model.selectedPage, .list(SnipList.inboxID))
        XCTAssertEqual(model.lastSelectedListID, SnipList.inboxID)

        let createdAgain = await model.createList(name: "Work")
        XCTAssertTrue(createdAgain)
        let nextWorkID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)
        model.selectPage(.clipboard)
        let deletedWhileOnClipboard = await model.deleteList(id: nextWorkID)
        XCTAssertTrue(deletedWhileOnClipboard)
        XCTAssertEqual(model.selectedPage, .clipboard)
        XCTAssertEqual(model.lastSelectedListID, SnipList.inboxID)
    }

    func testOpenNewListWithExistingDefaultNamesOpensANewEditor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("library.json"))
        let model = makeModel(library: library)
        await model.load()
        let base = String(localized: "New List")
        let created = await model.createList(name: base)
        XCTAssertTrue(created)
        let originalID = model.lastSelectedListID

        for suffix in 2...3 {
            model.searchText = "a search with no matches"
            await model.openNewList()

            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.selectedList.name, "\(base) (\(suffix))")
            XCTAssertNotEqual(model.lastSelectedListID, originalID)
            XCTAssertEqual(model.newListID, model.lastSelectedListID)
            XCTAssertEqual(model.editingListID, model.lastSelectedListID)
            XCTAssertEqual(model.searchText, "")
            XCTAssertEqual(model.lists.count, suffix + 1)
            model.finishListEditing(id: model.lastSelectedListID)
        }
        XCTAssertEqual(model.lists.first(where: { $0.id == originalID })?.name, base)
    }

    func testOpenNewListUsesCurrentLibraryWhenTheVisibleSnapshotIsStale() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("library.json"))
        let model = makeModel(library: library)
        await model.load()
        let base = String(localized: "New List")
        _ = try await library.perform(.createList(name: base, systemImage: "list.bullet"), sortedBy: .manual)
        XCTAssertEqual(model.lists.count, 1)

        await model.openNewList()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.selectedList.name, "\(base) (2)")
        XCTAssertEqual(model.editingListID, model.lastSelectedListID)
        XCTAssertEqual(model.newListID, model.lastSelectedListID)
        XCTAssertEqual(model.lists.count, 3)
    }

    func testCancelNewListRestoresOriginAndKeepsItsSnipsInInbox() async {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        let workCreated = await model.createList(name: "Work")
        XCTAssertTrue(workCreated)
        let workID = model.lastSelectedListID
        model.selectPage(.clipboard)
        await model.openNewList()
        let newListID = model.lastSelectedListID
        let created = await model.createSnip(content: "Keep this note", in: newListID)
        XCTAssertTrue(created)

        let cancelled = await model.cancelNewList(id: newListID)

        XCTAssertTrue(cancelled)
        XCTAssertEqual(model.selectedPage, .clipboard)
        XCTAssertEqual(model.lastSelectedListID, workID)
        XCTAssertFalse(model.lists.contains { $0.id == newListID })
        XCTAssertEqual(model.snips.first?.listID, SnipList.inboxID)
        XCTAssertNil(model.newListID)
        XCTAssertNil(model.editingListID)
    }

    func testCancelNewListFallsBackToInboxWhenItsOriginWasDeleted() async throws {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        let created = await model.createList(name: "Work")
        XCTAssertTrue(created)
        let workID = model.lastSelectedListID
        await model.openNewList()
        let newListID = try XCTUnwrap(model.newListID)
        XCTAssertEqual(model.newListOriginPage, .list(workID))

        let deletedOrigin = await model.deleteList(id: workID)
        XCTAssertTrue(deletedOrigin)
        XCTAssertEqual(model.newListCancellationPage, .list(SnipList.inboxID))
        let cancelled = await model.cancelNewList(id: newListID)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(model.selectedPage, .list(SnipList.inboxID))
        XCTAssertNil(model.newListID)
    }

    func testSavingNewListRejectsCancellationAndDuplicateSave() async throws {
        let library = ModelTestLibrary()
        let model = makeModel(library: library)
        await model.load()
        await model.openNewList()
        let list = model.selectedList
        let draft = model.listDraft(for: list)
        draft.name = "  Reading  "
        draft.systemImage = "book"
        await library.suspendNextCommand()
        let saving = Task { await model.saveListDraft(id: list.id) }
        await library.waitUntilFirstCommandStarts()

        XCTAssertTrue(draft.isSaving)
        let cancelled = await model.cancelNewList(id: list.id)
        let duplicateSave = await model.saveListDraft(id: list.id)
        XCTAssertFalse(cancelled)
        XCTAssertFalse(duplicateSave)
        XCTAssertEqual(model.selectedPage, .list(list.id))
        await library.resumeFirstCommand()

        let saved = await saving.value
        XCTAssertTrue(saved)
        let updated = try XCTUnwrap(model.lists.first { $0.id == list.id })
        XCTAssertEqual(updated.name, "Reading")
        XCTAssertEqual(updated.systemImage, "book")
        XCTAssertFalse(draft.isSaving)
        XCTAssertNil(model.newListID)
        XCTAssertNil(model.editingListID)
    }

    func testCancellationOwnsDraftDuringMotionAndReleasesItAfterInterruption() async {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        await model.openNewList()
        let list = model.selectedList
        let draft = model.listDraft(for: list)
        draft.name = "After interruption"
        let motionStarted = expectation(description: "Cancellation motion started")
        var settle: CheckedContinuation<Bool, Never>?
        let cancellation = Task {
            await model.cancelNewList(id: list.id) {
                await withCheckedContinuation {
                    settle = $0
                    motionStarted.fulfill()
                }
            }
        }
        await fulfillment(of: [motionStarted], timeout: 2)

        XCTAssertTrue(draft.isSaving)
        let saveDuringMotion = await model.saveListDraft(id: list.id)
        let duplicateCancel = await model.cancelNewList(id: list.id)
        XCTAssertFalse(saveDuringMotion)
        XCTAssertFalse(duplicateCancel)
        XCTAssertEqual(model.selectedPage, .list(list.id))
        cancellation.cancel()
        settle?.resume(returning: true)
        let cancelled = await cancellation.value

        XCTAssertFalse(cancelled)
        XCTAssertFalse(draft.isSaving)
        XCTAssertEqual(model.newListID, list.id)
        XCTAssertTrue(model.listDraft(for: list) === draft)
        let savedAfterInterruption = await model.saveListDraft(id: list.id)
        XCTAssertTrue(savedAfterInterruption)
        XCTAssertEqual(model.lists.first { $0.id == list.id }?.name, "After interruption")
    }

    func testCommittedCancellationSurvivesPresentationTaskCancellation() async {
        let library = ModelTestLibrary(rejectsCancelledCommands: true)
        let model = makeModel(library: library)
        await model.load()
        model.selectPage(.clipboard)
        await model.openNewList()
        let list = model.selectedList
        let draft = model.listDraft(for: list)
        await library.suspendNextCommand()
        let cancellation = Task { await model.cancelNewList(id: list.id) }
        await library.waitUntilFirstCommandStarts()
        XCTAssertEqual(model.selectedPage, .clipboard)
        XCTAssertTrue(draft.isSaving)
        cancellation.cancel() // Removing the page can invalidate SwiftUI's settlement task.
        await library.resumeFirstCommand()

        let cancelled = await cancellation.value
        XCTAssertTrue(cancelled)
        XCTAssertFalse(draft.isSaving)
        XCTAssertNil(model.newListID)
        XCTAssertNil(model.editingListID)
        XCTAssertEqual(model.lists.map(\.id), [SnipList.inboxID])
    }

    func testInterruptedCancellationReleasesDraftForRetry() async {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        await model.openNewList()
        let list = model.selectedList
        let draft = model.listDraft(for: list)

        let interrupted = await model.cancelNewList(id: list.id, beforeDeletion: { false })
        XCTAssertFalse(interrupted)
        XCTAssertFalse(draft.isSaving)
        XCTAssertEqual(model.selectedPage, .list(list.id))
        XCTAssertEqual(model.newListID, list.id)
        let cancelled = await model.cancelNewList(id: list.id)
        XCTAssertTrue(cancelled)
        XCTAssertNil(model.newListID)
    }

    func testFailedListDraftSaveRetainsEditsForRetry() async {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        _ = await model.createList(name: "Work")
        await model.openNewList()
        let list = model.selectedList
        let draft = model.listDraft(for: list)
        draft.name = "Work"

        let failedSave = await model.saveListDraft(id: list.id)
        XCTAssertFalse(failedSave)
        XCTAssertFalse(draft.isSaving)
        XCTAssertEqual(draft.name, "Work")
        XCTAssertEqual(model.editingListID, list.id)
        XCTAssertEqual(model.newListID, list.id)
        XCTAssertTrue(model.listDraft(for: list) === draft)
        draft.name = "Reading"
        let retry = await model.saveListDraft(id: list.id)
        XCTAssertTrue(retry)
        XCTAssertEqual(model.lists.first { $0.id == list.id }?.name, "Reading")
        XCTAssertNil(model.editingListID)
    }

    func testFailedCancellationReleasesDraftForSaving() async {
        let model = makeModel(library: ModelTestLibrary(failsListDeletion: true))
        await model.load()
        await model.openNewList()
        let list = model.selectedList
        let draft = model.listDraft(for: list)
        draft.name = "Keep this list"

        let cancelled = await model.cancelNewList(id: list.id)
        XCTAssertFalse(cancelled)
        XCTAssertFalse(draft.isSaving)
        XCTAssertEqual(model.selectedPage, .list(list.id))
        XCTAssertEqual(model.newListID, list.id)
        let saved = await model.saveListDraft(id: list.id)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.lists.first { $0.id == list.id }?.name, "Keep this list")
        XCTAssertNil(model.newListID)
    }

    func testSavingOneDraftDoesNotFinishAnotherListsEditor() async {
        let library = ModelTestLibrary()
        let model = makeModel(library: library)
        await model.load()
        _ = await model.createList(name: "Work")
        let workID = model.lastSelectedListID
        await model.openNewList()
        let list = model.selectedList
        let draft = model.listDraft(for: list)
        draft.name = "Reading"
        await library.suspendNextCommand()
        let saving = Task { await model.saveListDraft(id: list.id) }
        await library.waitUntilFirstCommandStarts()
        model.editListInline(id: workID)
        XCTAssertEqual(model.newListID, list.id)
        XCTAssertEqual(model.editingListID, workID)
        await library.resumeFirstCommand()

        let saved = await saving.value
        XCTAssertTrue(saved)
        XCTAssertEqual(model.editingListID, workID)
        XCTAssertEqual(model.selectedPage, .list(workID))
        XCTAssertNil(model.newListID)
    }

    func testNewListRequestDuringCancelCreatesAnotherListAfterDeletion() async {
        let library = ModelTestLibrary()
        let model = makeModel(library: library)
        await model.load()
        await model.openNewList()
        guard let cancelledID = model.newListID else { return XCTFail("New List did not open") }

        await library.suspendNextCommand()
        let cancellation = Task { await model.cancelNewList(id: cancelledID) }
        await library.waitUntilFirstCommandStarts()
        await model.openNewList()
        XCTAssertEqual(model.newListID, cancelledID)
        await library.resumeFirstCommand()

        let cancelled = await cancellation.value
        XCTAssertTrue(cancelled)
        guard let replacementID = model.newListID else { return XCTFail("Replacement list did not open") }
        XCTAssertNotEqual(replacementID, cancelledID)
        XCTAssertEqual(model.editingListID, replacementID)
        XCTAssertEqual(model.selectedPage, .list(replacementID))
        XCTAssertEqual(model.lists.count, 2)
    }

    func testNewListRequestDuringCancelIsDroppedAfterLeavingItsSourcePage() async {
        let library = ModelTestLibrary()
        let model = makeModel(library: library)
        await model.load()
        model.selectPage(.clipboard)
        await model.openNewList()
        guard let cancelledID = model.newListID else { return XCTFail("New List did not open") }

        await library.suspendNextCommand()
        let cancellation = Task { await model.cancelNewList(id: cancelledID) }
        await library.waitUntilFirstCommandStarts()
        XCTAssertEqual(model.selectedPage, .clipboard)
        await model.openNewList(ifSelectedPageIs: .clipboard)
        model.selectPage(.list(SnipList.inboxID))
        await library.resumeFirstCommand()

        let cancelled = await cancellation.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(model.selectedPage, .list(SnipList.inboxID))
        XCTAssertNil(model.newListID)
        XCTAssertNil(model.editingListID)
        XCTAssertEqual(model.lists.map(\.id), [SnipList.inboxID])
    }

    func testNewListRequestDuringCancelIsDroppedAfterLeavingAndReturning() async {
        let library = ModelTestLibrary()
        let model = makeModel(library: library)
        await model.load()
        model.selectPage(.clipboard)
        await model.openNewList()
        guard let cancelledID = model.newListID else { return XCTFail("New List did not open") }

        await library.suspendNextCommand()
        let cancellation = Task { await model.cancelNewList(id: cancelledID) }
        await library.waitUntilFirstCommandStarts()
        await model.openNewList(ifSelectedPageIs: .clipboard)
        model.selectPage(.list(SnipList.inboxID))
        model.selectPage(.clipboard)
        await library.resumeFirstCommand()

        let cancelled = await cancellation.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(model.selectedPage, .clipboard)
        XCTAssertNil(model.newListID)
        XCTAssertEqual(model.lists.map(\.id), [SnipList.inboxID])
    }

    func testFailedCancelDoesNotReplayNewListRequestAfterLeavingItsSourcePage() async {
        let library = ModelTestLibrary(failsListDeletion: true)
        let model = makeModel(library: library)
        await model.load()
        model.selectPage(.clipboard)
        await model.openNewList()
        guard let pendingID = model.newListID else { return XCTFail("New List did not open") }

        await library.suspendNextCommand()
        let cancellation = Task { await model.cancelNewList(id: pendingID) }
        await library.waitUntilFirstCommandStarts()
        XCTAssertEqual(model.selectedPage, .clipboard)
        await model.openNewList(ifSelectedPageIs: .clipboard)
        model.selectPage(.list(SnipList.inboxID))
        await library.resumeFirstCommand()

        let cancelled = await cancellation.value
        XCTAssertFalse(cancelled)
        XCTAssertEqual(model.selectedPage, .list(SnipList.inboxID))
        XCTAssertEqual(model.newListID, pendingID)
        XCTAssertEqual(model.editingListID, pendingID)
        XCTAssertTrue(model.lists.contains { $0.id == pendingID })
    }

    func testFailedCancelKeepsReturnedOriginAfterInterveningNavigation() async {
        let library = ModelTestLibrary(failsListDeletion: true)
        let model = makeModel(library: library)
        await model.load()
        model.selectPage(.clipboard)
        await model.openNewList()
        guard let pendingID = model.newListID else { return XCTFail("New List did not open") }

        await library.suspendNextCommand()
        let cancellation = Task { await model.cancelNewList(id: pendingID) }
        await library.waitUntilFirstCommandStarts()
        await model.openNewList(ifSelectedPageIs: .clipboard)
        model.selectPage(.list(SnipList.inboxID))
        model.selectPage(.clipboard)
        await library.resumeFirstCommand()

        let cancelled = await cancellation.value
        XCTAssertFalse(cancelled)
        XCTAssertEqual(model.selectedPage, .clipboard)
        XCTAssertEqual(model.newListID, pendingID)
        XCTAssertEqual(model.editingListID, pendingID)
        XCTAssertTrue(model.lists.contains { $0.id == pendingID })
    }

    func testRepeatedNewListRequestPreservesFirstEditorsCancelAction() async {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        let createdWork = await model.createList(name: "Work")
        XCTAssertTrue(createdWork)
        let workID = model.lastSelectedListID
        await model.openNewList()
        let pendingID = model.newListID
        let listCount = model.lists.count

        model.selectList(workID)
        model.editListInline(id: workID)
        XCTAssertEqual(model.lastSelectedListID, workID)
        XCTAssertEqual(model.editingListID, workID)

        model.selectList(workID)
        await model.openNewList()

        XCTAssertEqual(model.lastSelectedListID, pendingID)
        XCTAssertEqual(model.newListID, pendingID)
        XCTAssertEqual(model.editingListID, pendingID)
        XCTAssertEqual(model.lists.count, listCount)
        guard let pendingID else { return XCTFail("New List did not open") }
        let cancelled = await model.cancelNewList(id: pendingID)
        XCTAssertTrue(cancelled)
    }

    func testNewListCreationDoesNotPullSelectionBackAfterLeavingItsSourcePage() async {
        let library = ModelTestLibrary(suspendsFirstCommand: true)
        let model = makeModel(library: library)
        await model.load()
        model.selectPage(.clipboard)

        let creation = Task { await model.openNewList(ifSelectedPageIs: .clipboard) }
        await library.waitUntilFirstCommandStarts()
        model.selectPage(.list(SnipList.inboxID))
        await library.resumeFirstCommand()
        await creation.value

        XCTAssertEqual(model.selectedPage, .list(SnipList.inboxID))
        XCTAssertNil(model.newListID)
        XCTAssertEqual(model.lists.map(\.id), [SnipList.inboxID])
    }

    func testCancelledNewListCreationRollsBackAfterStoreCompletes() async {
        let library = ModelTestLibrary(suspendsFirstCommand: true)
        let model = makeModel(library: library)
        await model.load()
        model.selectPage(.clipboard)

        let creation = Task { await model.openNewList(ifSelectedPageIs: .clipboard) }
        await library.waitUntilFirstCommandStarts()
        creation.cancel()
        await library.resumeFirstCommand()
        await creation.value

        XCTAssertEqual(model.selectedPage, .clipboard)
        XCTAssertNil(model.newListID)
        XCTAssertEqual(model.lists.map(\.id), [SnipList.inboxID])
    }

    func testCancelledNewListRequestPreservesVisibleEditorDuringRefresh() async {
        let library = ModelTestLibrary()
        let model = IOSAppModel(
            library: library,
            userActions: DirectSnipLibraryUserActions(library: library),
            recoveryScope: SnipRecoveryScope("post-create-refresh")
        )
        await model.load()
        model.selectPage(.clipboard)
        await library.suspendNextRecovery()

        let creation = Task { await model.openNewList(ifSelectedPageIs: .clipboard) }
        await library.waitUntilRecoveryStarts()
        guard let openedID = model.newListID else {
            await library.resumeRecovery()
            await creation.value
            return XCTFail("New List editor was not opened before the refresh")
        }
        creation.cancel()
        await library.resumeRecovery()
        await creation.value

        XCTAssertEqual(model.selectedPage, .list(openedID))
        XCTAssertEqual(model.newListID, openedID)
        XCTAssertEqual(model.editingListID, openedID)
        XCTAssertEqual(model.lists.map(\.id), [SnipList.inboxID, openedID])
    }

    func testFinishingEditorDoesNotReleaseOutstandingCreationRefresh() async {
        let library = ModelTestLibrary()
        let model = IOSAppModel(
            library: library,
            userActions: DirectSnipLibraryUserActions(library: library),
            recoveryScope: SnipRecoveryScope("finish-during-refresh")
        )
        await model.load()
        await library.suspendNextRecovery()
        let creation = Task { await model.openNewList() }
        await library.waitUntilRecoveryStarts()
        guard let id = model.newListID else {
            await library.resumeRecovery()
            await creation.value
            return XCTFail("New List editor was not opened before the refresh")
        }
        model.finishListEditing(id: id)
        XCTAssertTrue(model.isCreatingList)
        await model.openNewList()
        XCTAssertNil(model.newListID)
        XCTAssertEqual(model.lists.count, 2)
        await library.resumeRecovery()
        await creation.value

        XCTAssertFalse(model.isCreatingList)
        await model.openNewList()
        XCTAssertNotNil(model.newListID)
        XCTAssertNotEqual(model.newListID, id)
        XCTAssertEqual(model.lists.count, 3)
    }

    func testCancelVisibleNewListWaitsForCreationRefreshAndDeletesOnce() async {
        let library = ModelTestLibrary()
        let model = IOSAppModel(
            library: library,
            userActions: DirectSnipLibraryUserActions(library: library),
            recoveryScope: SnipRecoveryScope("cancel-during-refresh")
        )
        await model.load()
        model.selectPage(.clipboard)
        await library.suspendNextRecovery()

        let creation = Task { await model.openNewList(ifSelectedPageIs: .clipboard) }
        await library.waitUntilRecoveryStarts()
        guard let openedID = model.newListID else {
            await library.resumeRecovery()
            await creation.value
            return XCTFail("New List editor was not opened before the refresh")
        }
        let cancellation = Task { await model.cancelNewList(id: openedID) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while model.selectedPage != .clipboard && clock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(model.selectedPage, .clipboard)
        await library.resumeRecovery()
        await creation.value

        let cancelled = await cancellation.value
        XCTAssertTrue(cancelled)
        XCTAssertNil(model.newListID)
        XCTAssertNil(model.editingListID)
        XCTAssertEqual(model.lists.map(\.id), [SnipList.inboxID])
    }

    func testNewListCreationDoesNotPullSelectionBackAfterLeavingAndReturning() async {
        let library = ModelTestLibrary(suspendsFirstCommand: true)
        let model = makeModel(library: library)
        await model.load()
        model.selectPage(.clipboard)

        let creation = Task { await model.openNewList(ifSelectedPageIs: .clipboard) }
        await library.waitUntilFirstCommandStarts()
        model.selectPage(.list(SnipList.inboxID))
        model.selectPage(.clipboard)
        await library.resumeFirstCommand()
        await creation.value

        XCTAssertEqual(model.selectedPage, .clipboard)
        XCTAssertNil(model.newListID)
        XCTAssertEqual(model.lists.map(\.id), [SnipList.inboxID])
    }

    func testSearchInvalidatesInFlightNewListCreationEvenAfterClosing() async {
        for closesSearchBeforeCompletion in [false, true] {
            let library = ModelTestLibrary(suspendsFirstCommand: true)
            let model = makeModel(library: library)
            await model.load()
            model.selectPage(.clipboard)

            let creation = Task { await model.openNewList(ifSelectedPageIs: .clipboard) }
            await library.waitUntilFirstCommandStarts()
            model.isSearchPresented = true
            if closesSearchBeforeCompletion { model.isSearchPresented = false }
            await library.resumeFirstCommand()
            await creation.value

            XCTAssertEqual(model.selectedPage, .clipboard)
            XCTAssertNil(model.newListID)
            XCTAssertEqual(model.lists.map(\.id), [SnipList.inboxID])
        }
    }

    func testReplacingLibraryClearsPendingNewListBeforeAnotherCreation() async {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        await model.openNewList()
        guard let oldID = model.newListID else { return XCTFail("New List did not open") }

        await model.replaceLibrary(ModelTestLibrary(), recoveryScope: nil)
        XCTAssertNil(model.newListID)
        XCTAssertNil(model.editingListID)
        XCTAssertEqual(model.selectedPage, .list(SnipList.inboxID))

        await model.openNewList()
        guard let replacementID = model.newListID else { return XCTFail("Replacement list did not open") }
        XCTAssertNotEqual(replacementID, oldID)
        XCTAssertEqual(model.selectedPage, .list(replacementID))
        XCTAssertEqual(model.lists.count, 2)
    }

    func testFailedRollbackSurfacesCreatedListEditor() async {
        let library = ModelTestLibrary(suspendsFirstCommand: true, failsListDeletion: true)
        let model = makeModel(library: library)
        await model.load()
        model.selectPage(.clipboard)

        let creation = Task { await model.openNewList(ifSelectedPageIs: .clipboard) }
        await library.waitUntilFirstCommandStarts()
        model.selectPage(.list(SnipList.inboxID))
        await library.resumeFirstCommand()
        await creation.value

        guard let survivingID = model.newListID else { return XCTFail("List should remain after failed rollback") }
        XCTAssertEqual(model.selectedPage, .list(survivingID))
        XCTAssertEqual(model.editingListID, survivingID)
        XCTAssertTrue(model.lists.contains { $0.id == survivingID })
        XCTAssertNotNil(model.errorMessage)
    }

    func testDuplicateListErrorUsesASpecificTitleAndResetsForOtherErrors() async {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        _ = await model.createList(name: "Work")
        let created = await model.createList(name: "Work")
        XCTAssertFalse(created)
        XCTAssertEqual(model.errorTitle, "Name Already Used")
        XCTAssertEqual(model.errorMessage, "A list with that name already exists. Choose another name.")
        model.errorMessage = "A different error"
        XCTAssertEqual(model.errorTitle, "Something Went Wrong")
    }

    func testInlineListDraftSurvivesNavigationUntilCompletion() async {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        await model.openNewList()
        let list = model.selectedList
        let draft = model.listDraft(for: list)
        draft.name = "Reading plans"
        draft.systemImage = "book"
        model.selectPage(.clipboard)
        model.selectList(SnipList.inboxID)
        model.selectList(list.id)
        XCTAssertTrue(model.listDraft(for: list) === draft)
        XCTAssertEqual(model.listDraft(for: list).name, "Reading plans")
        XCTAssertEqual(model.listDraft(for: list).systemImage, "book")
        XCTAssertEqual(model.editingListID, list.id)
        model.finishListEditing(id: list.id)
        XCTAssertNil(model.editingListID)
        XCTAssertNil(model.newListID)
        XCTAssertFalse(model.listDraft(for: list) === draft)
    }

    func testListFlowKeepsInboxAsFallback() async throws {
        let library = ModelTestLibrary()
        let model = makeModel(library: library)
        await model.load()

        let createdList = await model.createList(name: "Notes", color: .blue)
        XCTAssertTrue(createdList)
        let list = try XCTUnwrap(model.lists.first(where: { $0.name == "Notes" }))
        XCTAssertEqual(list.systemImage, "list.bullet")
        XCTAssertEqual(list.color, .blue)
        let createdSnip = await model.createSnip(content: "Keep me", in: list.id)
        XCTAssertTrue(createdSnip)
        let renamedList = await model.renameList(
            list, name: "Ideas", systemImage: list.systemImage, color: .set(.violet))
        XCTAssertTrue(renamedList)
        XCTAssertEqual(model.lists.first(where: { $0.id == list.id })?.name, "Ideas")
        XCTAssertEqual(model.lists.first(where: { $0.id == list.id })?.color, .violet)

        let deletedList = await model.deleteList(id: list.id)
        XCTAssertTrue(deletedList)
        XCTAssertEqual(model.lastSelectedListID, SnipList.inboxID)
        XCTAssertEqual(model.snips.first?.listID, SnipList.inboxID)
        XCTAssertEqual(model.lists.first?.id, SnipList.inboxID)
        XCTAssertEqual(model.lists.first?.name, SnipList.inbox.name)
    }

    func testListFlowStoresTheChosenIcon() async throws {
        let library = ModelTestLibrary()
        let model = makeModel(library: library)
        await model.load()

        let createdList = await model.createList(name: "Work", systemImage: "star.fill")
        XCTAssertTrue(createdList)
        let list = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" }))
        XCTAssertEqual(list.systemImage, "star.fill")

        let updatedList = await model.renameList(list, name: "Work", systemImage: "flame.fill")
        XCTAssertTrue(updatedList)
        XCTAssertEqual(model.lists.first(where: { $0.id == list.id })?.name, "Work")
        XCTAssertEqual(model.lists.first(where: { $0.id == list.id })?.systemImage, "flame.fill")
    }

    func testPublishesAllListsToTheShareDestinationCatalogWhenListsChange() async throws {
        var published: [[SnipList]] = []
        let library = ModelTestLibrary()
        let model = IOSAppModel(
            library: library,
            userActions: DirectSnipLibraryUserActions(library: library),
            publishShareDestinations: { published.append($0) }
        )

        await model.load()
        XCTAssertEqual(published.map { $0.map(\.name) }, [["Inbox"]])

        _ = await model.createList(name: "Work")
        let afterCreate = try XCTUnwrap(published.last)
        XCTAssertEqual(afterCreate.map(\.name), ["Inbox", "Work"])

        let workID = try XCTUnwrap(afterCreate.first { $0.name == "Work" }?.id)
        _ = await model.deleteList(id: workID)
        XCTAssertEqual(published.last?.map(\.name), ["Inbox"])
    }
}
