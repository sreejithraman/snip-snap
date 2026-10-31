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
final class IOSHapticFeedbackTests: XCTestCase {
    func testEveryOutcomeUsesTheSharedMeaningPolicy() {
        let groups: [(IOSHapticFeedback.Meaning, [IOSHapticFeedback.Kind])] = [
            (.selectionChanged, [.selection]),
            (.gestureCommitted, [.snap]),
            (.actionCompleted, [.saved, .copied, .markedDone, .reopened, .deleted, .restored, .moved]),
            (.significantSuccess, [.merged]),
            (.warning, [.warning]),
            (.error, [.error])
        ]
        let covered = groups.flatMap { $0.1 }
        XCTAssertEqual(covered.count, IOSHapticFeedback.Kind.allCases.count)
        for kind in IOSHapticFeedback.Kind.allCases {
            XCTAssertEqual(covered.filter { $0 == kind }.count, 1)
        }
        let player = RecordingHapticPlayer()
        let feedback = makeFeedback(player: player)
        for (meaning, outcomes) in groups {
            for outcome in outcomes {
                player.played.removeAll()
                feedback.emit(outcome, for: feedback.beginInteraction())
                XCTAssertEqual(player.played, [meaning], "Outcome: \(outcome)")
                XCTAssertEqual(feedback.event?.kind, outcome)
            }
        }
    }

    func testSaveAndDoneEmitFreshEventsAndUnchangedBatchStaysQuiet() async throws {
        let feedback = makeFeedback()
        let model = IOSAppModel(library: ModelTestLibrary(), haptics: feedback)
        await model.load()
        XCTAssertNil(feedback.event)

        let created = await model.createSnip(content: "First", in: SnipList.inboxID)
        XCTAssertTrue(created)
        let saved = try XCTUnwrap(feedback.event)
        XCTAssertEqual(saved.kind, .saved)
        let snip = try XCTUnwrap(model.snips.first)
        let edited = await model.editSnip(snip, content: "Edited")
        XCTAssertTrue(edited)
        XCTAssertEqual(feedback.event?.kind, .saved)
        XCTAssertNotEqual(feedback.event?.id, saved.id)

        let markedDone = await model.toggleDone(id: snip.id)
        XCTAssertTrue(markedDone)
        let done = try XCTUnwrap(feedback.event)
        XCTAssertEqual(done.kind, .markedDone)
        model.selectedSnipIDs = [snip.id]
        let unchanged = await model.setSelectionDone(true)
        XCTAssertTrue(unchanged)
        XCTAssertEqual(feedback.event, done)

        let reopened = await model.setSelectionDone(false)
        XCTAssertTrue(reopened)
        XCTAssertEqual(feedback.event?.kind, .reopened)
        XCTAssertNotEqual(feedback.event?.id, done.id)
        let latest = feedback.event
        await model.load()
        XCTAssertEqual(feedback.event, latest)
    }

    func testSelectionFeedbackExcludesSameSelectionAndProgrammaticResets() {
        let feedback = makeFeedback()
        let model = IOSAppModel(library: ModelTestLibrary(), haptics: feedback)
        let id = UUID()
        model.selectSnips([id])
        XCTAssertEqual(feedback.event?.kind, .selection)
        let selected = feedback.event
        model.selectSnips([id])
        XCTAssertEqual(feedback.event, selected)
        model.selectSnips([])
        XCTAssertNotEqual(feedback.event, selected)
        let deselected = feedback.event
        model.selectedSnipIDs = [id]
        model.selectList(SnipList.inboxID)
        XCTAssertEqual(feedback.event, deselected)
    }

    func testRepeatedCopyWorksWhileUndoToastIsVisibleAndReportsWriteFailures() async throws {
        let feedback = makeFeedback()
        let snip = Snip(content: "Copy me", origin: .quickEntry, pinnedAt: Date())
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]), haptics: feedback)
        await model.load()
        let undo = AppToast.deleted(count: 1, id: UUID())
        model.presentToast(undo)
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        await coordinator.copyText(snips: [snip], model: model)
        let first = try XCTUnwrap(feedback.event)
        XCTAssertEqual(first.kind, .copied)
        await coordinator.copy(snips: [snip], model: model)
        XCTAssertEqual(feedback.event?.kind, .copied)
        XCTAssertNotEqual(feedback.event?.id, first.id)
        XCTAssertEqual(model.toast?.id, undo.id)

        pasteboard.succeeds = false
        await coordinator.copyText(snips: [snip], model: model)
        let failure = try XCTUnwrap(feedback.event)
        XCTAssertEqual(failure.kind, .error)
        XCTAssertEqual(model.failure?.operation, "clipboard.write")
        await coordinator.copyText(snips: [snip], model: model)
        XCTAssertEqual(feedback.event?.kind, .error)
        XCTAssertNotEqual(feedback.event?.id, failure.id)
    }

    func testUnavailableCopyWarnsAndCancelDoesNotEmitCompletion() async throws {
        let feedback = makeFeedback()
        var snip = Snip(content: "Text remains", origin: .quickEntry, pinnedAt: Date())
        snip.attachments = [try testAttachment(id: UUID(), fileName: "missing.txt")]
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]), haptics: feedback)
        await model.load()
        let coordinator = IOSCopyShareCoordinator(pasteboard: RecordingPasteboard())
        await coordinator.copy(snips: [snip], model: model)
        XCTAssertNotNil(coordinator.unavailableFilesNotice)
        XCTAssertEqual(feedback.event?.kind, .warning)
        let warning = feedback.event
        coordinator.cancelUnavailableFilesNotice()
        XCTAssertEqual(feedback.event, warning)
        await coordinator.copy(snips: [snip], model: model)
        await coordinator.copyTextFromNotice(try XCTUnwrap(coordinator.unavailableFilesNotice), model: model)
        XCTAssertEqual(feedback.event?.kind, .copied)
    }

    func testUnavailableShareStaysQuietAndSupersedesOlderFeedback() async throws {
        let feedback = makeFeedback()
        var snip = Snip(content: "Share me", origin: .quickEntry)
        snip.attachments = [try testAttachment(id: UUID(), fileName: "missing.txt")]
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]), haptics: feedback)
        await model.load()
        let coordinator = IOSCopyShareCoordinator(pasteboard: RecordingPasteboard())
        let pending = feedback.beginInteraction()

        await coordinator.share(snips: [snip], model: model)

        XCTAssertNotNil(coordinator.unavailableFilesNotice)
        XCTAssertNil(coordinator.shareRequest)
        XCTAssertNil(feedback.event)
        feedback.emit(.saved, for: pending)
        XCTAssertNil(feedback.event)
    }

    func testFailedSaveReportsErrorWithoutSuccess() async {
        let feedback = makeFeedback()
        let model = IOSAppModel(library: ModelTestLibrary(), haptics: feedback)
        let missing = Snip(content: "Missing", origin: .quickEntry)
        let edited = await model.editSnip(missing, content: "New text")
        XCTAssertFalse(edited)
        XCTAssertEqual(feedback.event?.kind, .error)
        XCTAssertNotNil(model.errorMessage)
    }

    func testPreferencePersistsAndDiscardsWorkStartedBeforeTurningOff() {
        let suite = "haptics-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let feedback = IOSHapticFeedback(defaults: defaults)
        XCTAssertTrue(feedback.isEnabled)
        feedback.isActive = true
        let pending = feedback.beginInteraction()
        feedback.isEnabled = false
        XCTAssertFalse(IOSHapticFeedback(defaults: defaults).isEnabled)
        feedback.isEnabled = true
        feedback.emit(.saved, for: pending)
        XCTAssertNil(feedback.event)
        feedback.isEnabled = false
        feedback.emit(.selection, for: feedback.beginInteraction())
        XCTAssertNil(feedback.event)
    }

    func testLeavingOrCancellingASaveSuppressesLateFeedback() async {
        for reason in 0..<3 {
            let feedback = makeFeedback()
            let library = ModelTestLibrary(suspendsFirstCommand: true)
            let model = IOSAppModel(library: library, haptics: feedback)
            let save = Task { await model.createSnip(content: "Pending", in: SnipList.inboxID) }
            await library.waitUntilFirstCommandStarts()
            switch reason {
            case 0: model.selectList(UUID())
            case 1:
                feedback.isActive = false
                feedback.isActive = true
            default: save.cancel()
            }
            await library.resumeFirstCommand()
            _ = await save.value
            XCTAssertNil(feedback.event, "Pending feedback must stop for reason \(reason)")
        }
    }

    func testNewActionSupersedesFeedbackFromAnOlderSave() async throws {
        let feedback = makeFeedback()
        let copiedSnip = Snip(content: "Copy now", origin: .quickEntry, pinnedAt: Date())
        let library = ModelTestLibrary(snips: [copiedSnip], suspendsFirstCommand: true)
        let model = IOSAppModel(library: library, haptics: feedback)
        await model.load()
        let save = Task { await model.createSnip(content: "Pending", in: SnipList.inboxID) }
        await library.waitUntilFirstCommandStarts()
        let coordinator = IOSCopyShareCoordinator(pasteboard: RecordingPasteboard())
        await coordinator.copyText(snips: [copiedSnip], model: model)
        let copied = try XCTUnwrap(feedback.event)
        XCTAssertEqual(copied.kind, .copied)

        await library.resumeFirstCommand()
        let saved = await save.value

        XCTAssertTrue(saved)
        XCTAssertEqual(feedback.event, copied)
    }

    func testSwitchingInlineEditorsSuppressesFeedbackFromThePreviousSave() async {
        let feedback = makeFeedback()
        let first = Snip(content: "First", origin: .quickEntry)
        let second = Snip(content: "Second", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [first, second], suspendsFirstCommand: true)
        let model = IOSAppModel(library: library, haptics: feedback)
        await model.load()
        model.beginEditingSnip(first.id)
        let save = Task { await model.editSnip(first, content: "Saved first") }
        await library.waitUntilFirstCommandStarts()

        model.beginEditingSnip(second.id)
        await library.resumeFirstCommand()
        let saved = await save.value

        XCTAssertTrue(saved)
        XCTAssertNil(feedback.event)
        XCTAssertEqual(model.selectedSnipID, second.id)
        XCTAssertEqual(model.snips.first(where: { $0.id == first.id })?.content, "Saved first")
    }

    func testNewActionsSuppressFeedbackFromAPendingAttachmentCopy() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for action in 0..<4 {
            let feedback = makeFeedback()
            let attachment = try testAttachment(id: UUID(), fileName: "note.txt")
            var snip = Snip(content: "Copy me", origin: .quickEntry)
            snip.attachments = [attachment]
            let handler = IOSCloudSyncHandlerProbe(states: [attachment.id: .waiting])
            let library = ModelTestLibrary(snips: [snip])
            let session = IOSAppSession(
                library: library,
                syncedContentSettings: SyncedContentSettingsModel(mode: .iCloudSync),
                cloudSyncSession: IOSCloudSyncSessionProbe(result: .noChange, activeLibrary: library),
                cloudSyncHandler: handler,
                haptics: feedback
            )
            let model = session.model
            await model.load()
            model.selectedSnipIDs = [snip.id]
            let pasteboard = RecordingPasteboard()
            let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
            let copy = Task { await coordinator.copyAttachments(snips: [snip], model: model) }
            await handler.waitUntilPrepareStarts()

            switch action {
            case 0:
                model.endSelectingSnips()
            case 1:
                let deleted = await model.deleteSnip(id: snip.id)
                XCTAssertTrue(deleted)
            case 2:
                model.selectList(model.lastSelectedListID)
            default:
                await session.retrySyncWhenPossible()
            }
            await handler.finishPrepare(with: .success(file))
            await copy.value

            XCTAssertEqual(pasteboard.writes.count, 1)
            if action == 1 { XCTAssertEqual(feedback.event?.kind, .deleted) }
            else { XCTAssertNil(feedback.event) }
            if action == 0 || action == 1 { XCTAssertTrue(model.selectedSnipIDs.isEmpty) }
            if action == 2 { XCTAssertEqual(model.selectedSnipIDs, [snip.id]) }
        }
    }

    func testDirectPlaybackHonorsPreferenceAndLifecycle() {
        let player = RecordingHapticPlayer()
        let feedback = makeFeedback(player: player)
        feedback.emit(.copied, for: feedback.beginInteraction())
        feedback.emit(.markedDone, for: feedback.beginInteraction())
        XCTAssertEqual(player.played, [.actionCompleted, .actionCompleted])
        let pending = feedback.beginInteraction()
        feedback.isEnabled = false
        feedback.emit(.saved, for: feedback.beginInteraction())
        feedback.isEnabled = true
        feedback.emit(.copied, for: pending)
        XCTAssertEqual(player.played.count, 2)
        let active = feedback.beginInteraction()
        feedback.isActive = false
        feedback.emit(.markedDone, for: active)
        XCTAssertEqual(player.played.count, 2)
        feedback.isActive = true
        feedback.emit(.markedDone, for: feedback.beginInteraction())
        XCTAssertEqual(player.played, [.actionCompleted, .actionCompleted, .actionCompleted])
    }

    func testSingleAndBatchDoneUseTheSameOutcomeAndNoOpStaysQuiet() async throws {
        let first = Snip(content: "First", origin: .quickEntry)
        let second = Snip(content: "Second", origin: .quickEntry)
        let player = RecordingHapticPlayer()
        let feedback = makeFeedback(player: player)
        let model = IOSAppModel(library: ModelTestLibrary(snips: [first, second]), haptics: feedback)
        await model.load()
        let singleDone = await model.toggleDone(id: first.id)
        XCTAssertTrue(singleDone)
        model.selectedSnipIDs = [second.id]
        let batchDone = await model.setSelectionDone(true)
        XCTAssertTrue(batchDone)
        XCTAssertEqual(player.played, [.actionCompleted, .actionCompleted])
        let noOp = await model.setSelectionDone(true)
        XCTAssertTrue(noOp)
        XCTAssertEqual(player.played.count, 2)
        let singleNotDone = await model.toggleDone(id: first.id)
        XCTAssertTrue(singleNotDone)
        let batchNotDone = await model.setSelectionDone(false)
        XCTAssertTrue(batchNotDone)
        XCTAssertEqual(player.played, [.actionCompleted, .actionCompleted, .actionCompleted, .actionCompleted])
    }

    func testAllCopyVariantsReachTheSameFeedbackSeam() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let attachment = try testAttachment(id: UUID(), fileName: "note.txt")
        var snip = Snip(content: "Copy me", origin: .quickEntry)
        snip.attachments = [attachment]
        let player = RecordingHapticPlayer()
        let feedback = makeFeedback(player: player)
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip], attachmentURLs: [attachment.id: file]), haptics: feedback)
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
        await coordinator.copyText(snips: [snip], model: model)
        await coordinator.copy(snips: [snip], model: model)
        await coordinator.copyAttachments(snips: [snip], model: model)
        XCTAssertEqual(pasteboard.writes.count, 3)
        XCTAssertEqual(player.played, [.actionCompleted, .actionCompleted, .actionCompleted])
    }

    func testCombinedOutcomesEmitOnceWithFailurePrecedence() {
        let player = RecordingHapticPlayer()
        let feedback = makeFeedback(player: player)
        let outcomes: [IOSHapticFeedback.Kind] = [.copied, .markedDone]
        feedback.emit(outcomes, for: feedback.beginInteraction())
        XCTAssertEqual(player.played, [.actionCompleted])
        XCTAssertEqual(feedback.event?.kinds, outcomes)
        feedback.emit([.error, .copied], for: feedback.beginInteraction())
        XCTAssertEqual(player.played, [.actionCompleted, .error])
        let latest = feedback.event
        feedback.emit([], for: feedback.beginInteraction())
        XCTAssertEqual(feedback.event, latest)
        let stale = feedback.beginInteraction()
        feedback.isEnabled = false
        feedback.isEnabled = true
        feedback.emit(outcomes, for: stale)
        XCTAssertEqual(player.played.count, 2)
    }

    func testSingleBatchAndListDeletionEmitAfterSuccessAndMissingIDsStayQuiet() async throws {
        let first = Snip(content: "First", origin: .quickEntry)
        let second = Snip(content: "Second", origin: .quickEntry)
        let third = Snip(content: "Third", origin: .quickEntry)
        let player = RecordingHapticPlayer()
        let feedback = makeFeedback(player: player)
        let model = IOSAppModel(library: ModelTestLibrary(snips: [first, second, third]), haptics: feedback)
        await model.load()
        let single = await model.deleteSnip(id: first.id)
        XCTAssertTrue(single)
        XCTAssertFalse(model.snips.contains { $0.id == first.id })
        XCTAssertEqual(player.played, [.actionCompleted])
        model.selectedSnipIDs = [second.id, third.id]
        let batch = await model.deleteSelection()
        XCTAssertTrue(batch)
        XCTAssertTrue(model.snips.isEmpty)
        XCTAssertEqual(player.played, [.actionCompleted, .actionCompleted])
        let missing = await model.deleteSnip(id: first.id)
        XCTAssertFalse(missing)
        let empty = await model.deleteSelection()
        XCTAssertFalse(empty)
        XCTAssertEqual(player.played.count, 2)
        let createdList = await model.createList(name: "Temporary")
        XCTAssertTrue(createdList)
        let list = try XCTUnwrap(model.lists.first { $0.id != SnipList.inboxID })
        let deletedList = await model.deleteList(id: list.id)
        XCTAssertTrue(deletedList)
        XCTAssertEqual(player.played, [.actionCompleted, .actionCompleted, .actionCompleted])
    }

    func testFailedDeletionEmitsErrorAndKeepsTheSnip() async {
        let snip = Snip(content: "Keep me", origin: .quickEntry)
        let feedback = makeFeedback()
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip], failsDeletion: true), haptics: feedback)
        await model.load()
        let deleted = await model.deleteSnip(id: snip.id)
        XCTAssertFalse(deleted)
        XCTAssertEqual(model.snips.map(\.id), [snip.id])
        XCTAssertEqual(feedback.event?.kind, .error)
    }

    func testUndoMoveAndMergeUseSystemFeedbackWithoutAddingReorderFeedback() async throws {
        for mode in [SnipSortMode.chronological, .manual] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("library.json"))
            let player = RecordingHapticPlayer()
            let feedback = makeFeedback(player: player)
            let model = IOSAppModel(library: library, haptics: feedback)
            await model.load()
            let addedFirst = await model.createSnip(content: "First", in: SnipList.inboxID)
            let addedSecond = await model.createSnip(content: "Second", in: SnipList.inboxID)
            let addedList = await model.createList(name: "Work")
            XCTAssertTrue(addedFirst && addedSecond && addedList)
            let first = try XCTUnwrap(model.snips.first { $0.content == "First" })
            let second = try XCTUnwrap(model.snips.first { $0.content == "Second" })
            let work = try XCTUnwrap(model.lists.first { $0.name == "Work" })
            model.sortMode = mode
            let deleted = await model.deleteSnip(id: first.id)
            XCTAssertTrue(deleted)
            let undo = try XCTUnwrap(model.toast)
            player.played.removeAll()
            await model.performToastActionNow(undo)
            XCTAssertTrue(model.snips.contains { $0.id == first.id })
            XCTAssertEqual(player.played, [.actionCompleted])
            await model.performToastActionNow(undo)
            XCTAssertEqual(player.played, [.actionCompleted])

            player.played.removeAll()
            let moved = await model.moveSnip(id: first.id, to: work.id)
            XCTAssertTrue(moved)
            XCTAssertEqual(player.played, [.actionCompleted])
            let sameList = await model.moveSnip(id: first.id, to: work.id)
            XCTAssertTrue(sameList)
            XCTAssertEqual(player.played, [.actionCompleted])
            model.selectList(SnipList.inboxID)
            model.selectedSnipIDs = [second.id]
            let batch = await model.moveSelection(to: work.id)
            XCTAssertTrue(batch)
            XCTAssertEqual(player.played, [.actionCompleted, .actionCompleted])
            model.selectList(work.id)
            player.played.removeAll()
            let reordered = await model.placeVisibleSnips(Array(model.visibleSnips.map(\.id).reversed()))
            XCTAssertTrue(reordered)
            XCTAssertTrue(player.played.isEmpty)

            model.selectedSnipIDs = [first.id, second.id]
            let merged = await model.mergeSelection()
            XCTAssertTrue(merged)
            XCTAssertEqual(model.visibleSnips.count, 1)
            XCTAssertEqual(player.played, [.significantSuccess])
            let tooFew = await model.mergeSelection()
            XCTAssertFalse(tooFew)
            XCTAssertEqual(player.played, [.significantSuccess])
            let mergedID = try XCTUnwrap(model.visibleSnips.first?.id)
            let failedMove = await model.moveSnip(id: mergedID, to: UUID())
            XCTAssertFalse(failedMove)
            XCTAssertEqual(player.played.last, .error)
        }
    }

    private func makeFeedback(player: RecordingHapticPlayer = RecordingHapticPlayer()) -> IOSHapticFeedback {
        let suite = "haptics-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let feedback = IOSHapticFeedback(defaults: defaults, player: player)
        feedback.isActive = true
        return feedback
    }
}
