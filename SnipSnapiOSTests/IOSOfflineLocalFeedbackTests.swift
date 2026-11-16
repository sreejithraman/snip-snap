import Foundation
import SnipSnapCore
import SnipSnapPersistence
import UIKit
import XCTest
@testable import SnipSnapiOS

@MainActor
final class IOSOfflineLocalFeedbackTests: XCTestCase {
    // Setup may use the suite's cold-Simulator allowance; local completion gets two seconds.
    private let promptBudget: Duration = .seconds(2)

    func testCopyCommitsDoneAndShowsSnappedWhilePriorLoadRefreshIsSuspended() async throws {
        try await checkCopyWhileRefreshIsSuspended(markDone: false)
    }

    func testDoneCopiesAndShowsSnappedWhilePriorLoadRefreshIsSuspended() async throws {
        try await checkCopyWhileRefreshIsSuspended(markDone: true)
    }

    func testSendFinishesWhilePriorLoadRefreshIsSuspended() async throws {
        try await checkSendWhileRefreshIsSuspended(priorLoad: true)
    }

    func testSendFinishesAfterLocalCommitWhileItsTrailingRefreshIsSuspended() async throws {
        try await checkSendWhileRefreshIsSuspended(priorLoad: false)
    }

    private func checkCopyWhileRefreshIsSuspended(markDone: Bool) async throws {
        try await withFixture { fixture in
            let snip = try XCTUnwrap(fixture.model.snips.first)
            await fixture.handler.arm(fixture.pause)
            fixture.start { await fixture.model.load(); return true }
            guard await fixture.pause.entered.wait(for: .seconds(30)) else {
                XCTFail("The prior load did not enter syncedAttachmentStates")
                return
            }

            let action = fixture.start {
                if markDone {
                    return await fixture.coordinator.toggleDone(snip: snip, model: fixture.model)
                }
                return await fixture.coordinator.copy(snips: [snip], model: fixture.model)
            }
            guard await fixture.writer.written.wait(for: .seconds(30)) else {
                XCTFail("Copy did not reach the system pasteboard")
                return
            }
            XCTAssertTrue(fixture.pause.isHeld)
            XCTAssertEqual(fixture.board.string, OfflineFixture.originalText)
            let completed = await action.finished.wait(for: promptBudget)
            XCTAssertTrue(fixture.pause.isHeld, "Completion must be checked before network release")
            XCTAssertTrue(completed, "Copy/Done must finish while attachment-state lookup is held")
            XCTAssertEqual(action.result, true, "Only a committed local action is success")
            XCTAssertEqual(fixture.model.snips.first { $0.id == snip.id }?.isDone, true)
            let persisted = try await fixture.reopenSnapshot()
            XCTAssertEqual(persisted.snips.first { $0.id == snip.id }?.isDone, true)
            XCTAssertNil(fixture.model.errorMessage)
            XCTAssertEqual(fixture.model.toast?.message, String(localized: "Snapped"))
            let copied = String(localized: "Copied")
            let done = String(localized: "Marked Done")
            XCTAssertEqual(fixture.model.toast?.detail, String(localized: "\(copied) · \(done)"))
            XCTAssertEqual(fixture.model.toast?.action, .undoDone)
            XCTAssertTrue(fixture.pause.isHeld)

            // Exercise the offered undo after the held-network assertions, including durable readback.
            let toast = fixture.model.toast
            guard await fixture.settle() else { return }
            let durable = try await fixture.reopenSnapshot()
            XCTAssertEqual(durable.snips.first { $0.id == snip.id }?.isDone, true)
            if completed, action.result == true, let toast {
                let undo = fixture.start {
                    await fixture.model.performToastActionNow(toast)
                    return true
                }
                let undone = await undo.finished.wait(for: .seconds(30))
                XCTAssertTrue(undone, "The offered Done undo must be usable")
                if undone {
                    let reopened = try await fixture.reopenSnapshot()
                    XCTAssertEqual(reopened.snips.first { $0.id == snip.id }?.isDone, false)
                    XCTAssertEqual(fixture.board.string, OfflineFixture.originalText)
                }
            }
        }
    }

    private func checkSendWhileRefreshIsSuspended(priorLoad: Bool) async throws {
        try await withFixture { fixture in
            let text = "Send this draft without waiting for iCloud"
            fixture.composer.draftStore.setText(text, for: SnipList.inboxID)
            fixture.composer.draftStore.flushText()
            await fixture.handler.arm(fixture.pause)
            if priorLoad {
                fixture.start { await fixture.model.load(); return true }
                guard await fixture.pause.entered.wait(for: .seconds(30)) else {
                    XCTFail("The prior load did not enter syncedAttachmentStates")
                    return
                }
            }
            let admitted = OfflineSignal()
            let saving = fixture.start {
                await fixture.composer.save(listID: SnipList.inboxID) { draft in
                    admitted.fire()
                    return await fixture.model.createSnip(
                        content: draft.text, in: SnipList.inboxID,
                        attachmentURLs: draft.attachments, selectCreatedSnip: false
                    )
                }
            }
            guard await admitted.wait(for: .seconds(30)) else {
                XCTFail("The composer did not admit its draft")
                return
            }
            if !priorLoad {
                guard await fixture.pause.entered.wait(for: .seconds(30)) else {
                    XCTFail("The add's trailing refresh did not enter syncedAttachmentStates")
                    return
                }
                let committed = try await fixture.reopenSnapshot()
                XCTAssertEqual(committed.snips.filter { $0.content == text }.count, 1,
                               "This scenario must reach the refresh after committing the add")
                XCTAssertEqual(fixture.model.snips.filter { $0.content == text }.count, 1)
            }
            XCTAssertTrue(fixture.pause.isHeld)
            let completed = await saving.finished.wait(for: promptBudget)
            XCTAssertTrue(fixture.pause.isHeld, "Completion must be checked before network release")
            XCTAssertTrue(completed, "Send must finish without awaiting attachment-state lookup")
            XCTAssertEqual(saving.result, true)
            let persisted = try await fixture.reopenSnapshot()
            XCTAssertEqual(persisted.snips.filter { $0.content == text }.count, 1)
            XCTAssertEqual(fixture.model.snips.filter { $0.content == text }.count, 1)
            XCTAssertFalse(fixture.composer.isSaving)
            XCTAssertNil(fixture.composer.savingListID)
            if saving.result == false {
                XCTAssertEqual(fixture.composer.draftStore.draft(for: SnipList.inboxID).text, text,
                               "A failed save must retain the draft")
            } else {
                XCTAssertEqual(fixture.composer.draftStore.draft(for: SnipList.inboxID), ComposerDraft(),
                               "A successful Send must finalize its draft before network release")
            }
            XCTAssertNil(fixture.model.errorMessage)
            XCTAssertTrue(fixture.pause.isHeld)
            guard await fixture.settle() else { return }
            let durable = try await fixture.reopenSnapshot()
            XCTAssertEqual(durable.snips.filter { $0.content == text }.count, 1)
            if saving.result == false {
                XCTAssertEqual(fixture.composer.draftStore.draft(for: SnipList.inboxID).text, text)
            }
        }
    }

    private func withFixture(_ check: (OfflineFixture) async throws -> Void) async throws {
        let fixture = try await OfflineFixture.make()
        do {
            try await check(fixture)
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }
}

// This app-side seam deliberately does not claim the package fixture's managed cloud admission.
@MainActor
private final class OfflineFixture {
    static let originalText = "Copy this text while the control lookup is held"
    let root: URL
    let storeURL: URL
    let suite: String
    let defaults: UserDefaults
    let boardName: UIPasteboard.Name
    let board: UIPasteboard
    let writer: OfflinePasteboardWriter
    let coordinator: IOSCopyShareCoordinator
    let composer: CompactComposerStorage
    let model: IOSAppModel
    let handler = OfflineAttachmentStateHandler()
    let pause = OfflinePause()
    private var work: [OfflineWork] = []

    private init(root: URL, suite: String, defaults: UserDefaults,
                 boardName: UIPasteboard.Name, board: UIPasteboard, library: SwiftDataSnipLibrary,
                 snapshot: SnipLibrarySnapshot) {
        self.root = root
        storeURL = root.appendingPathComponent("snips.store")
        self.suite = suite
        self.defaults = defaults
        self.boardName = boardName
        self.board = board
        writer = OfflinePasteboardWriter(system: IOSSystemPasteboard(
            pasteboard: board, stagingRoot: root.appendingPathComponent("pasteboard")))
        coordinator = IOSCopyShareCoordinator(pasteboard: writer)
        composer = CompactComposerStorage(defaults: defaults)
        let assembly = SnipLibraryAssembly(library: library, activeCloudNamespace: nil)
        model = IOSAppModel(library: assembly.library, userActions: assembly.userActions,
                            userActionsFactory: assembly.userActionsFactory,
                            initialSnapshot: snapshot, cloudSyncHandler: handler,
                            haptics: IOSHapticFeedback(defaults: defaults, player: RecordingHapticPlayer()))
    }

    static func make() async throws -> OfflineFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineFeedback-\(UUID())")
        let suite = "OfflineFeedback.\(UUID())"
        let boardName = UIPasteboard.Name("OfflineFeedback.\(UUID())")
        do {
            let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("snips.store"))
            _ = try await library.perform(.add(content: originalText, origin: .quickEntry, source: nil,
                listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: .distantPast),
                sortedBy: .manual)
            let snapshot = try await library.checkedSnapshot(sortedBy: .manual)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let board = try XCTUnwrap(UIPasteboard(name: boardName, create: true))
            return OfflineFixture(root: root, suite: suite, defaults: defaults,
                                  boardName: boardName, board: board, library: library, snapshot: snapshot)
        } catch {
            UIPasteboard.remove(withName: boardName)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func reopenSnapshot() async throws -> SnipLibrarySnapshot {
        let reader = try SwiftDataSnipLibrary(storeURL: storeURL)
        return try await reader.checkedSnapshot(sortedBy: .manual)
    }

    @discardableResult
    func start(_ operation: @escaping @MainActor () async -> Bool) -> OfflineWork {
        let next = OfflineWork(operation)
        work.append(next)
        return next
    }

    func settle() async -> Bool {
        pause.release()
        var settled = true
        let deadline = ContinuousClock.now + .seconds(30)
        for operation in work {
            let finished = await operation.finished.wait(for: deadline - ContinuousClock.now)
            XCTAssertTrue(finished, "An owned task did not settle after release")
            if finished { await operation.task?.value }
            else { operation.task?.cancel(); settled = false }
        }
        return settled
    }

    func cleanUp() async {
        // An unstructured cleanup task can drain even when the test's caller was cancelled.
        let cleanup = Task { @MainActor in
            work.forEach { $0.task?.cancel() }
            if await settle() {
                composer.draftStore.flushText()
                defaults.removePersistentDomain(forName: suite)
                UIPasteboard.remove(withName: boardName)
                try? FileManager.default.removeItem(at: root)
            }
        }
        await cleanup.value
    }
}

@MainActor
private final class OfflineWork {
    let finished = OfflineSignal()
    private(set) var result: Bool?
    private(set) var task: Task<Void, Never>?

    init(_ operation: @escaping @MainActor () async -> Bool) {
        task = Task { [self] in
            result = await operation()
            finished.fire()
        }
    }
}

@MainActor
private final class OfflinePasteboardWriter: IOSPasteboardWriting {
    let written = OfflineSignal()
    private let system: IOSSystemPasteboard
    init(system: IOSSystemPasteboard) { self.system = system }
    func write(_ items: [IOSCopyItem]) -> Bool {
        guard system.write(items) else { return false }
        written.fire()
        return true
    }
}

private actor OfflineAttachmentStateHandler: OptionalCloudSyncHandling {
    private var nextPause: OfflinePause?
    func arm(_ pause: OfflinePause) { nextPause = pause }
    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? { nil }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {}
    func syncWhenPossible() async {}
    func scheduleSyncAfterLocalChange() async {}
    func isCloudSyncActive() async throws -> Bool { true }
    func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] {
        let pause = nextPause
        nextPause = nil
        try await pause?.suspend()
        return [:]
    }
    func clearDownloadedFiles() async throws {}
    func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL {
        throw SnipLibraryError.attachmentCopyFailed
    }
}

private final class OfflinePause: Sendable {
    let entered = OfflineSignal()
    private let released = OfflineSignal()
    private let exited = OfflineSignal()
    var isHeld: Bool { entered.isSet && !released.isSet && !exited.isSet }
    func suspend() async throws {
        defer { exited.fire() }
        entered.fire()
        guard await released.wait() else { throw CancellationError() }
    }
    func release() { released.fire() }
}

// A timeout ends only the observation. It never releases the simulated network operation.
private final class OfflineSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var isSet: Bool { lock.withLock { fired } }

    func fire() {
        let pending = lock.withLock {
            fired = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume(returning: true) }
    }

    func wait() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Bool? = lock.withLock {
                    if fired { return true }
                    if Task.isCancelled { return false }
                    waiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let pending = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            pending?.resume(returning: false)
        }
    }

    func wait(for timeout: Duration) async -> Bool {
        if isSet { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.wait() }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch {}
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
