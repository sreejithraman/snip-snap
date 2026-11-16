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

import Observation
import SnipSnapCloud

// These guards exercise the app protocol boundary, independently of the package transport proof.
private final class StatusGuardGate: @unchecked Sendable {
    let entered = OfflineSignal()
    let cancelled = OfflineSignal()
    private let lock = NSLock()
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var isHeld: Bool { entered.isSet && lock.withLock { !released } }

    // Deliberately noncooperative: cancellation is observed, but only the test releases the call.
    func suspend() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { pending in
                let resume = lock.withLock {
                    if released { return true }
                    continuations.append(pending)
                    return false
                }
                entered.fire()
                if resume { pending.resume() }
            }
        } onCancel: {
            self.cancelled.fire()
        }
    }

    func release() {
        let pending = lock.withLock {
            released = true
            let pending = continuations
            continuations.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }
}

private actor StatusGuardHandler: OptionalCloudSyncHandling {
    enum Call: Hashable, Sendable { case mode, states, prepare, clear }
    struct Counts: Sendable {
        var entries: [Call: Int] = [:]
        var activeStatus = 0
        var maximumActiveStatus = 0
    }
    struct Reply<Value: Sendable>: Sendable {
        let gate: StatusGuardGate?
        let result: Result<Value, SnipLibraryError>
    }
    private var modes: [Reply<Bool>] = []
    private var states: [Reply<[UUID: SyncedAttachmentTransferState]>] = []
    private var preparations: [Reply<URL>] = []
    private var clears: [StatusGuardGate] = []
    private var activeMode = true
    private var currentStates: [UUID: SyncedAttachmentTransferState]
    private var preparedURL: URL
    private var counts = Counts()
    private var signals: [Call: [Int: OfflineSignal]] = [:]
    private var activeCalls = 0
    private var idle = OfflineSignal()

    init(id: UUID, preparedURL: URL) {
        currentStates = [id: .waiting]
        self.preparedURL = preparedURL
        idle.fire()
    }
    func enqueueMode(_ result: Result<Bool, SnipLibraryError>, gate: StatusGuardGate) {
        modes.append(Reply(gate: gate, result: result))
    }
    func enqueueStates(_ result: Result<[UUID: SyncedAttachmentTransferState], SnipLibraryError>,
                       gate: StatusGuardGate) {
        states.append(Reply(gate: gate, result: result))
    }
    func enqueuePrepare(_ url: URL, gate: StatusGuardGate) {
        preparations.append(Reply(gate: gate, result: .success(url)))
    }
    func enqueueClear(_ gate: StatusGuardGate) { clears.append(gate) }
    func set(mode: Bool, states: [UUID: SyncedAttachmentTransferState]) {
        activeMode = mode
        currentStates = states
    }
    func setPreparedURL(_ url: URL) { preparedURL = url }
    func snapshotCounts() -> Counts { counts }
    func idleSignal() -> OfflineSignal { idle }
    func entry(_ call: Call, number: Int) -> OfflineSignal {
        if let signal = signals[call]?[number] { return signal }
        let signal = OfflineSignal()
        if counts.entries[call, default: 0] >= number { signal.fire() }
        signals[call, default: [:]][number] = signal
        return signal
    }
    private func begin(_ call: Call) {
        if activeCalls == 0 { idle = OfflineSignal() }
        activeCalls += 1
        counts.entries[call, default: 0] += 1
        if call == .mode || call == .states {
            counts.activeStatus += 1
            counts.maximumActiveStatus = max(counts.maximumActiveStatus, counts.activeStatus)
        }
        signals[call]?[counts.entries[call, default: 0]]?.fire()
    }
    private func end(_ call: Call) {
        activeCalls -= 1
        if call == .mode || call == .states { counts.activeStatus -= 1 }
        if activeCalls == 0 { idle.fire() }
    }
    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? { nil }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {}
    func syncWhenPossible() async {}
    func scheduleSyncAfterLocalChange() async {}
    func isCloudSyncActive() async throws -> Bool {
        begin(.mode)
        defer { end(.mode) }
        let reply = modes.isEmpty ? Reply(gate: nil, result: .success(activeMode)) : modes.removeFirst()
        await reply.gate?.suspend()
        return try reply.result.get()
    }
    func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] {
        begin(.states)
        defer { end(.states) }
        let reply = states.isEmpty ? Reply(gate: nil, result: .success(currentStates)) : states.removeFirst()
        await reply.gate?.suspend()
        return try reply.result.get()
    }
    func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL {
        begin(.prepare)
        defer { end(.prepare) }
        let reply = preparations.isEmpty ? Reply(gate: nil, result: .success(preparedURL)) : preparations.removeFirst()
        await reply.gate?.suspend()
        return try reply.result.get()
    }
    func clearDownloadedFiles() async throws {
        begin(.clear)
        defer { end(.clear) }
        let gate = clears.isEmpty ? nil : clears.removeFirst()
        await gate?.suspend()
    }
}

@MainActor
private final class StatusGuardFixture {
    static let attachmentID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let snipID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    struct Store {
        let library: SwiftDataSnipLibrary
        let url: URL
        let snapshot: SnipLibrarySnapshot
    }
    let root: URL
    let original: Store
    let originalPrepared: URL
    let replacementPrepared: URL
    let handler: StatusGuardHandler
    var model: IOSAppModel?
    private var gates: [StatusGuardGate] = []
    private var work: [OfflineWork] = []

    private init(root: URL, original: Store, oldFile: URL, newFile: URL) {
        self.root = root
        self.original = original
        originalPrepared = oldFile
        replacementPrepared = newFile
        handler = StatusGuardHandler(id: Self.attachmentID, preparedURL: oldFile)
        model = IOSAppModel(library: original.library, initialSnapshot: original.snapshot,
                            cloudSyncHandler: handler)
    }
    static func make() async throws -> StatusGuardFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StatusGuards-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let oldFile = root.appendingPathComponent("verified-old.txt")
            let newFile = root.appendingPathComponent("verified-new.txt")
            try Data("old!".utf8).write(to: oldFile)
            try Data("new!".utf8).write(to: newFile)
            let original = try await makeStore(root: root, name: "original", content: "Original source", bytes: "old!")
            return StatusGuardFixture(root: root, original: original, oldFile: oldFile, newFile: newFile)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
    private static func makeStore(root: URL, name: String, content: String, bytes: String) async throws -> Store {
        let url = root.appendingPathComponent(name).appendingPathComponent("snips.store")
        let library = try SwiftDataSnipLibrary(storeURL: url)
        let attachment = try testAttachment(id: attachmentID, fileName: "payload.txt", byteCount: 4)
        let snip = Snip(id: snipID, content: content, origin: .quickEntry, attachments: [attachment])
        _ = try await library.mergeTransferSnapshot(SnipLibraryTransferSnapshot(
            revision: 0, snips: [snip], lists: [.inbox], attachmentData: [attachmentID: Data(bytes.utf8)]
        ), transitionID: UUID(), expectedTargetDigest: nil)
        let snapshot = try await library.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(snapshot.snips.map(\.id), [snipID], "Fixture import must retain the supplied ID")
        XCTAssertEqual(snapshot.snips.map(\.content), [content])
        let local = try XCTUnwrap(snapshot.attachmentURLs[attachmentID])
        XCTAssertEqual(try Data(contentsOf: local), Data(bytes.utf8))
        return Store(library: library, url: url, snapshot: snapshot)
    }
    func replacement() async throws -> Store {
        try await Self.makeStore(root: root, name: "replacement", content: "Replacement source", bytes: "new!")
    }
    func reopen(_ store: Store) async throws -> SnipLibrarySnapshot {
        try await SwiftDataSnipLibrary(storeURL: store.url).checkedSnapshot(sortedBy: .manual)
    }
    func gate() -> StatusGuardGate {
        let gate = StatusGuardGate()
        gates.append(gate)
        return gate
    }
    @discardableResult
    func start(_ operation: @escaping @MainActor () async -> Bool) -> OfflineWork {
        let task = OfflineWork(operation)
        work.append(task)
        return task
    }
    func ready(_ signal: OfflineSignal, _ stage: String) async -> Bool {
        let ready = await signal.wait(for: .seconds(30))
        XCTAssertTrue(ready, "Guard setup/readiness failed: \(stage)")
        return ready
    }
    func completed(_ operation: OfflineWork, _ contract: String) async -> Bool {
        let completed = await operation.finished.wait(for: .seconds(2))
        XCTAssertTrue(completed, contract)
        return completed
    }
    func cleanUp() async {
        let cleanup = Task { @MainActor in
            gates.forEach { $0.release() }
            work.forEach { $0.task?.cancel() }
            let deadline = ContinuousClock.now + .seconds(30)
            var settled = true
            for operation in work {
                let done = await operation.finished.wait(for: deadline - ContinuousClock.now)
                XCTAssertTrue(done, "Guard cleanup could not join an owned caller")
                if done { await operation.task?.value } else { settled = false }
            }
            if settled, let model {
                let draining = OfflineWork { await model.load(); return true }
                let done = await draining.finished.wait(for: deadline - ContinuousClock.now)
                XCTAssertTrue(done, "Guard cleanup could not drain status work")
                if done { await draining.task?.value }
                else { draining.task?.cancel(); settled = false }
            }
            model = nil
            let idle = await handler.idleSignal()
            let done = await idle.wait(for: deadline - ContinuousClock.now)
            XCTAssertTrue(done, "Guard cleanup left an external handler call suspended")
            if settled && done { try? FileManager.default.removeItem(at: root) }
        }
        await cleanup.value
    }
}

private actor StatusGuardRetrySession: IOSCloudSyncSessionHandling {
    let gate: StatusGuardGate
    let result: SnipSnapCloudSyncResult
    let library: any SnipLibrary
    private var retries = 0
    private var synchronizations = 0
    private var schedules = 0
    init(gate: StatusGuardGate, result: SnipSnapCloudSyncResult, library: any SnipLibrary) {
        self.gate = gate
        self.result = result
        self.library = library
    }
    func retrySynchronization() async throws -> SnipSnapCloudSyncResult {
        retries += 1
        await gate.suspend()
        return result
    }
    func synchronize() async throws -> SnipSnapCloudSyncResult {
        synchronizations += 1
        await gate.suspend()
        return result
    }
    func scheduleAutomaticSync() async {
        schedules += 1
        await gate.suspend()
    }
    func iosActiveLibrary() async throws -> (library: any SnipLibrary, recoveryScope: SnipRecoveryScope?) {
        return (library, nil)
    }
    func counts() -> [Int] { [retries, synchronizations, schedules] }
}

extension IOSOfflineLocalFeedbackTests {
    func testAwaitedLoadPublishesCheckedAttachmentStatesBeforeReturning() async throws {
        try await withStatusGuard { fixture in
            let model = try XCTUnwrap(fixture.model)
            let gate = fixture.gate()
            await fixture.handler.enqueueStates(.success([StatusGuardFixture.attachmentID: .failed]), gate: gate)
            let loading = fixture.start { await model.load(); return true }
            guard await fixture.ready(gate.entered, "load reached the state read") else { return }
            let returnedEarly = await loading.finished.wait(for: .milliseconds(100))
            XCTAssertFalse(returnedEarly, "Awaited load must not finish before status arrives")
            XCTAssertTrue(gate.isHeld)
            gate.release()
            guard await fixture.ready(loading.finished, "load returned after state release") else { return }
            XCTAssertTrue(model.isCloudSyncActive)
            XCTAssertEqual(model.attachmentTransferState(for: StatusGuardFixture.attachmentID), .failed)
            XCTAssertNil(model.attachmentURL(for: StatusGuardFixture.attachmentID))
            XCTAssertNil(model.errorMessage, "Passive failed status is not an action error")
        }
    }

    func testAwaitedLoadEstablishesLocalModeWithoutHoldingTheLocalMutationLease() async throws {
        try await withStatusGuard { fixture in
            let model = try XCTUnwrap(fixture.model)
            let gate = fixture.gate()
            await fixture.handler.set(mode: false, states: [:])
            await fixture.handler.enqueueMode(.success(false), gate: gate)
            let loading = fixture.start { await model.load(); return true }
            guard await fixture.ready(gate.entered, "load reached the mode read") else { return }
            let adding = fixture.start {
                await model.createSnip(content: "Committed while mode was unknown", in: SnipList.inboxID)
            }
            guard await fixture.completed(adding, "A mode read must not hold local mutation access") else { return }
            XCTAssertEqual(adding.result, true)
            let durable = try await fixture.reopen(fixture.original)
            XCTAssertEqual(Set(durable.snips.map(\.content)), ["Original source", "Committed while mode was unknown"])
            XCTAssertEqual(durable.snips.count, 2)
            let returnedEarly = await loading.finished.wait(for: .milliseconds(100))
            XCTAssertFalse(returnedEarly)
            XCTAssertTrue(gate.isHeld)
            gate.release()
            guard await fixture.ready(loading.finished, "load established local-only mode") else { return }
            XCTAssertFalse(model.isCloudSyncActive)
            let local = try XCTUnwrap(model.usableAttachmentURL(for: StatusGuardFixture.attachmentID))
            XCTAssertEqual(try Data(contentsOf: local), Data("old!".utf8))
            let calls = await fixture.handler.snapshotCounts()
            XCTAssertEqual(calls.entries[.states, default: 0], 0)
        }
    }

    func testRepeatedRequestsCoalesceWhileModeReadIgnoresCancellation() async throws {
        try await checkCoalescing(modeRead: true)
    }

    func testRepeatedRequestsCoalesceWhileStateReadIgnoresCancellation() async throws {
        try await checkCoalescing(modeRead: false)
    }

    private func checkCoalescing(modeRead: Bool) async throws {
        try await withStatusGuard { fixture in
            let model = try XCTUnwrap(fixture.model)
            let first = fixture.gate()
            let latest = fixture.gate()
            let id = StatusGuardFixture.attachmentID
            if modeRead {
                await fixture.handler.enqueueMode(.success(false), gate: first)
            } else {
                await fixture.handler.enqueueStates(.success([id: .failed]), gate: first)
            }
            await fixture.handler.enqueueStates(.success([id: .available]), gate: latest)
            let loading = fixture.start { await model.load(); return true }
            guard await fixture.ready(first.entered, "first noncooperative read") else { return }
            for text in ["First local change", "Second local change", "Third local change"] {
                let adding = fixture.start { await model.createSnip(content: text, in: SnipList.inboxID) }
                guard await fixture.completed(adding, "Repeated local changes must finish before status release") else { return }
                XCTAssertEqual(adding.result, true)
            }
            let extraMode = await fixture.handler.entry(.mode, number: 2)
            let enteredEarly = await extraMode.wait(for: .milliseconds(100))
            XCTAssertFalse(enteredEarly, "A held read must not spawn another status caller")
            let held = await fixture.handler.snapshotCounts()
            XCTAssertEqual(held.entries[.mode], 1)
            XCTAssertEqual(held.entries[.states, default: 0], modeRead ? 0 : 1)
            XCTAssertEqual(held.activeStatus, 1)
            XCTAssertEqual(held.maximumActiveStatus, 1)
            XCTAssertTrue(first.isHeld)
            first.release()
            guard await fixture.ready(latest.entered, "coalesced current status read") else { return }
            let returnedEarly = await loading.finished.wait(for: .milliseconds(100))
            XCTAssertFalse(returnedEarly, "Load must join the meaningful follow-up")
            latest.release()
            guard await fixture.ready(loading.finished, "latest status established") else { return }
            XCTAssertTrue(model.isCloudSyncActive)
            XCTAssertEqual(model.attachmentTransferState(for: id), .available)
            let durable = try await fixture.reopen(fixture.original)
            XCTAssertEqual(Set(durable.snips.map(\.content)), ["Original source", "First local change",
                "Second local change", "Third local change"])
            XCTAssertEqual(durable.snips.count, 4)
            XCTAssertEqual(Set(model.snips.map(\.content)), ["Original source", "First local change",
                "Second local change", "Third local change"])
            let extra = await fixture.handler.entry(.mode, number: 3)
            let surplus = await extra.wait(for: .milliseconds(100))
            XCTAssertFalse(surplus, "Repeated requests should collapse to one current follow-up")
            let finished = await fixture.handler.snapshotCounts()
            XCTAssertEqual(finished.entries[.mode], 2)
            XCTAssertEqual(finished.entries[.states], modeRead ? 1 : 2)
            XCTAssertEqual(finished.maximumActiveStatus, 1)
        }
    }

    func testReplacementRejectsOldInactiveModeWithoutClearingNewPreparedBytes() async throws {
        try await checkReplacement(stale: .inactiveMode)
    }

    func testReplacementRejectsOldFailedStatesWithoutClearingNewPreparedBytes() async throws {
        try await checkReplacement(stale: .failedStates)
    }

    func testReplacementRejectsOldModeErrorBeforeTheNewModeReturns() async throws {
        try await checkReplacement(stale: .modeError)
    }

    func testReplacementRejectsOldStateErrorBeforeTheNewModeReturns() async throws {
        try await checkReplacement(stale: .stateError)
    }

    private enum StaleStatus: Equatable { case inactiveMode, failedStates, modeError, stateError }

    private func checkReplacement(stale: StaleStatus) async throws {
        try await withStatusGuard { fixture in
            let model = try XCTUnwrap(fixture.model)
            let initial = fixture.start { await model.load(); return true }
            guard await fixture.ready(initial.finished, "initial current cloud knowledge") else { return }
            XCTAssertTrue(model.isCloudSyncActive)
            let old = fixture.gate()
            let current = fixture.gate()
            let id = StatusGuardFixture.attachmentID
            let localReplacement = stale == .modeError || stale == .stateError
            switch stale {
            case .inactiveMode: await fixture.handler.enqueueMode(.success(false), gate: old)
            case .failedStates: await fixture.handler.enqueueStates(.success([id: .failed]), gate: old)
            case .modeError: await fixture.handler.enqueueMode(.failure(.storeUnavailable), gate: old)
            case .stateError: await fixture.handler.enqueueStates(.failure(.storeUnavailable), gate: old)
            }
            let loading = fixture.start { await model.load(); return true }
            guard await fixture.ready(old.entered, "old source status held") else { return }
            let replacement = try await fixture.replacement()
            await fixture.handler.setPreparedURL(fixture.replacementPrepared)
            if localReplacement {
                await fixture.handler.set(mode: false, states: [:])
                await fixture.handler.enqueueMode(.success(false), gate: current)
            } else {
                await fixture.handler.enqueueStates(.success([id: .waiting]), gate: current)
            }
            let changed = observeStatusGuardSnapshot(model)
            let replacing = fixture.start {
                await model.replaceLibrary(replacement.library, recoveryScope: nil)
                return true
            }
            guard await fixture.ready(changed, "replacement local snapshot published") else { return }
            XCTAssertEqual(model.snips.map(\.content), ["Replacement source"])
            let durable = try await fixture.reopen(replacement)
            XCTAssertEqual(durable.snips.map(\.content), ["Replacement source"])
            var prepared: URL?
            let preparing = fixture.start {
                prepared = await model.prepareAttachment(id, for: .preview)
                return prepared != nil
            }
            guard await fixture.completed(preparing, "Current source preparation must not wait on old status") else { return }
            XCTAssertEqual(prepared, fixture.replacementPrepared)
            XCTAssertEqual(try Data(contentsOf: fixture.replacementPrepared), Data("new!".utf8))
            // Eviction forces another real prepare; an old reply must not invalidate that new-source operation.
            try FileManager.default.removeItem(at: fixture.replacementPrepared)
            let currentPrepareGate = fixture.gate()
            await fixture.handler.enqueuePrepare(fixture.replacementPrepared, gate: currentPrepareGate)
            let currentPreparing = fixture.start {
                prepared = await model.prepareAttachment(id, for: .preview)
                return prepared != nil
            }
            guard await fixture.ready(currentPrepareGate.entered, "new source prepare held after cache eviction") else { return }
            XCTAssertTrue(old.isHeld)
            old.release()
            guard await fixture.ready(current.entered, "new source status held after old reply") else { return }
            XCTAssertEqual(model.attachmentTransferState(for: id), .syncing,
                           "Old status must not overwrite a live new-source preparation")
            XCTAssertEqual(model.isCloudSyncActive, !localReplacement,
                           "An old mode error cannot restore the former source's cloud mode")
            XCTAssertNil(model.errorMessage)
            XCTAssertTrue(current.isHeld)
            try Data("new!".utf8).write(to: fixture.replacementPrepared)
            currentPrepareGate.release()
            guard await fixture.completed(currentPreparing, "Old status must not invalidate a current prepare") else { return }
            XCTAssertEqual(prepared, fixture.replacementPrepared)
            XCTAssertEqual(model.usableAttachmentURL(for: id), fixture.replacementPrepared)
            XCTAssertEqual(try Data(contentsOf: fixture.replacementPrepared), Data("new!".utf8))
            current.release()
            guard await fixture.ready(replacing.finished, "replacement completed with current status"),
                  await fixture.ready(loading.finished, "older load settled") else { return }
            XCTAssertEqual(model.snips.map(\.content), ["Replacement source"])
            if localReplacement {
                XCTAssertFalse(model.isCloudSyncActive)
                let url = try XCTUnwrap(model.usableAttachmentURL(for: id))
                XCTAssertEqual(try Data(contentsOf: url), Data("new!".utf8))
            } else {
                XCTAssertEqual(model.attachmentTransferState(for: id), .waiting)
                XCTAssertNil(model.attachmentURL(for: id), "Replacement ends without a prepared cache entry")
                let fresh = fixture.start {
                    prepared = await model.prepareAttachment(id, for: .preview)
                    return prepared != nil
                }
                guard await fixture.completed(fresh, "New source remains preparable") else { return }
                XCTAssertEqual(prepared, fixture.replacementPrepared)
            }
        }
    }

    func testCancellingOneLoadLeavesSharedStatusAndAnotherLoadWaiting() async throws {
        try await withStatusGuard { fixture in
            let model = try XCTUnwrap(fixture.model)
            let gate = fixture.gate()
            await fixture.handler.enqueueStates(.success([StatusGuardFixture.attachmentID: .waiting]), gate: gate)
            let first = fixture.start { await model.load(); return true }
            guard await fixture.ready(gate.entered, "shared status held") else { return }
            let admitted = OfflineSignal()
            let second = fixture.start { admitted.fire(); await model.load(); return true }
            guard await fixture.ready(admitted, "second public load invoked") else { return }
            first.task?.cancel()
            guard await fixture.completed(first, "Cancelling a load must end only its own wait") else { return }
            let returnedEarly = await second.finished.wait(for: .milliseconds(100))
            let cancelledShared = await gate.cancelled.wait(for: .milliseconds(100))
            XCTAssertFalse(returnedEarly)
            XCTAssertFalse(cancelledShared, "One waiter must not cancel the owned shared read")
            XCTAssertTrue(gate.isHeld)
            gate.release()
            guard await fixture.ready(second.finished, "remaining load established status") else { return }
            XCTAssertTrue(model.isCloudSyncActive)
            XCTAssertEqual(model.attachmentTransferState(for: StatusGuardFixture.attachmentID), .waiting)
        }
    }

    func testStalledStatusWorkerDoesNotRetainModelAndObservesDeallocationCancellation() async throws {
        try await withStatusGuard { fixture in
            let gate = fixture.gate()
            await fixture.handler.enqueueStates(.success([StatusGuardFixture.attachmentID: .waiting]), gate: gate)
            weak var weakModel = fixture.model
            let creating = fixture.start {
                await fixture.model?.createSnip(content: "Durable before deallocation", in: SnipList.inboxID) == true
            }
            guard await fixture.ready(gate.entered, "owned status read is stalled") else { return }
            guard await fixture.completed(creating, "Durable creation must return before status release") else { return }
            XCTAssertEqual(creating.result, true)
            await creating.task?.value
            let durable = try await fixture.reopen(fixture.original)
            XCTAssertTrue(durable.snips.contains { $0.content == "Durable before deallocation" })
            fixture.model = nil
            XCTAssertNil(weakModel, "The status task must not strongly retain its model across network waits")
            let cancelled = await gate.cancelled.wait(for: .seconds(2))
            XCTAssertTrue(cancelled, "Model deallocation must cancel its owned status task")
            XCTAssertTrue(gate.isHeld, "The noncooperative fixture remains held until test cleanup releases it")
            gate.release()
            let idle = await fixture.handler.idleSignal()
            guard await fixture.ready(idle, "deallocated worker left the external boundary") else { return }
            XCTAssertNil(weakModel)
        }
    }

    func testCacheClearRejectsBytesFromPreparationThatFinishesAfterClear() async throws {
        try await withStatusGuard { fixture in
            let model = try XCTUnwrap(fixture.model)
            let loading = fixture.start { await model.load(); return true }
            guard await fixture.ready(loading.finished, "initial attachment knowledge") else { return }
            let gate = fixture.gate()
            await fixture.handler.enqueuePrepare(fixture.originalPrepared, gate: gate)
            var prepared: URL?
            let preparing = fixture.start {
                prepared = await model.prepareAttachment(StatusGuardFixture.attachmentID, for: .preview)
                return prepared != nil
            }
            guard await fixture.ready(gate.entered, "prepare held before cache clear") else { return }
            let clearing = fixture.start { await model.clearDownloadedFiles(); return true }
            guard await fixture.completed(clearing, "Cache clear must finish independently of this held prepare") else { return }
            XCTAssertTrue(gate.isHeld)
            XCTAssertNil(model.attachmentURL(for: StatusGuardFixture.attachmentID))
            gate.release()
            guard await fixture.ready(preparing.finished, "invalidated prepare returned") else { return }
            XCTAssertNil(prepared)
            XCTAssertNil(model.usableAttachmentURL(for: StatusGuardFixture.attachmentID))
            XCTAssertEqual(model.attachmentTransferState(for: StatusGuardFixture.attachmentID), .waiting)
            XCTAssertNil(model.errorMessage)
        }
    }

    func testReplacementRejectsLateOldPrepareWithIdenticalAttachmentMetadata() async throws {
        try await withStatusGuard { fixture in
            let model = try XCTUnwrap(fixture.model)
            let loading = fixture.start { await model.load(); return true }
            guard await fixture.ready(loading.finished, "initial attachment knowledge") else { return }
            let gate = fixture.gate()
            await fixture.handler.enqueuePrepare(fixture.originalPrepared, gate: gate)
            var oldURL: URL?
            let preparing = fixture.start {
                oldURL = await model.prepareAttachment(StatusGuardFixture.attachmentID, for: .preview)
                return oldURL != nil
            }
            guard await fixture.ready(gate.entered, "old source prepare held") else { return }
            let replacement = try await fixture.replacement()
            await fixture.handler.setPreparedURL(fixture.replacementPrepared)
            let replacing = fixture.start { await model.replaceLibrary(replacement.library, recoveryScope: nil); return true }
            guard await fixture.completed(replacing, "Replacement must not join an old source prepare") else { return }
            gate.release()
            guard await fixture.ready(preparing.finished, "old source prepare returned") else { return }
            XCTAssertNil(oldURL, "Matching ID, filename and byte count do not make old-source bytes current")
            XCTAssertNil(model.attachmentURL(for: StatusGuardFixture.attachmentID))
            var currentURL: URL?
            let current = fixture.start {
                currentURL = await model.prepareAttachment(StatusGuardFixture.attachmentID, for: .preview)
                return currentURL != nil
            }
            guard await fixture.completed(current, "New source preparation succeeds") else { return }
            let url = try XCTUnwrap(currentURL)
            XCTAssertEqual(try Data(contentsOf: url), Data("new!".utf8))
            XCTAssertEqual(model.usableAttachmentURL(for: StatusGuardFixture.attachmentID), url)
            let durable = try await fixture.reopen(replacement)
            XCTAssertEqual(durable.snips.map(\.content), ["Replacement source"])
        }
    }

    func testOldCacheClearCannotEvictAReplacementSourcesPreparedFile() async throws {
        try await withStatusGuard { fixture in
            let model = try XCTUnwrap(fixture.model)
            let loading = fixture.start { await model.load(); return true }
            guard await fixture.ready(loading.finished, "initial attachment knowledge") else { return }
            let gate = fixture.gate()
            await fixture.handler.enqueueClear(gate)
            let clearing = fixture.start { await model.clearDownloadedFiles(); return true }
            guard await fixture.ready(gate.entered, "old clear request held") else { return }
            let replacement = try await fixture.replacement()
            await fixture.handler.setPreparedURL(fixture.replacementPrepared)
            let replacing = fixture.start { await model.replaceLibrary(replacement.library, recoveryScope: nil); return true }
            guard await fixture.completed(replacing, "New source adopted while old clear waits") else { return }
            var prepared: URL?
            let preparing = fixture.start {
                prepared = await model.prepareAttachment(StatusGuardFixture.attachmentID, for: .preview)
                return prepared != nil
            }
            guard await fixture.completed(preparing, "Replacement file verified") else { return }
            XCTAssertEqual(prepared, fixture.replacementPrepared)
            gate.release()
            guard await fixture.ready(clearing.finished, "old clear reply returned") else { return }
            let url = try XCTUnwrap(model.usableAttachmentURL(for: StatusGuardFixture.attachmentID))
            XCTAssertEqual(url, fixture.replacementPrepared)
            XCTAssertEqual(try Data(contentsOf: url), Data("new!".utf8))
            XCTAssertNil(model.errorMessage)
        }
    }

    func testTryAgainWaitsForCheckedRetryAndAdoptionBeforeShowingCurrentIssue() async throws {
        try await checkGuardedRetry(result: .libraryReplacedWithSyncIssue(.someChangesPending),
                                   expected: .failed(.someChangesPending), adopts: true)
    }

    func testTryAgainClearsPriorFailureOnlyAfterAdoptedCollectionSettles() async throws {
        try await checkGuardedRetry(result: .libraryReplacedAndSyncCompleted, expected: .ready, adopts: true)
    }

    func testTryAgainThatOnlyFetchesRetainsPriorFailureAfterAwaitedReload() async throws {
        try await checkGuardedRetry(result: .contentUpdated, expected: .failed(.retryingSoon), adopts: false)
    }

    private func checkGuardedRetry(result: SnipSnapCloudSyncResult,
                                   expected: SyncedContentSettingsState, adopts: Bool) async throws {
        try await withStatusGuard { fixture in
            fixture.model = nil
            let replacement = try await fixture.replacement()
            let gate = fixture.gate()
            let status = fixture.gate()
            let retry = StatusGuardRetrySession(gate: gate, result: result, library: replacement.library)
            let settings = SyncedContentSettingsModel(mode: .iCloudSync)
            settings.recordSyncFailure(.retryingSoon)
            let session = IOSAppSession(library: fixture.original.library,
                initialSnapshot: fixture.original.snapshot, syncedContentSettings: settings,
                cloudSyncSession: retry, cloudSyncHandler: fixture.handler,
                clipboardRootURL: fixture.root.appendingPathComponent("clipboard"))
            fixture.model = session.model
            await fixture.handler.enqueueStates(.success([StatusGuardFixture.attachmentID: .waiting]), gate: status)
            let trying = fixture.start { await session.retrySyncWhenPossible(); return true }
            guard await fixture.ready(gate.entered, "explicit checked retry held") else { return }
            let returnedEarly = await trying.finished.wait(for: .milliseconds(100))
            XCTAssertFalse(returnedEarly, "Try Again must await the checked retry")
            XCTAssertFalse(settings.canSyncNow)
            XCTAssertEqual(settings.state, .failed(.retryingSoon))
            let overlap = fixture.start { await session.retrySyncWhenPossible(); return true }
            guard await fixture.completed(overlap, "An overlapping Try Again must be rejected") else { return }
            let calls = await retry.counts()
            XCTAssertEqual(calls, [1, 0, 0], "Try Again uses retry, not synchronize or automatic scheduling")
            gate.release()
            guard await fixture.ready(status.entered, "checked result reached awaited model reload") else { return }
            XCTAssertEqual(session.model.snips.map(\.content), adopts ? ["Replacement source"] : ["Original source"])
            XCTAssertEqual(settings.state, .failed(.retryingSoon), "Current issue/success must follow the adopted reload")
            let finishedReloadEarly = await trying.finished.wait(for: .milliseconds(100))
            XCTAssertFalse(finishedReloadEarly)
            XCTAssertTrue(status.isHeld)
            status.release()
            guard await fixture.ready(trying.finished, "explicit retry and reload completed") else { return }
            XCTAssertEqual(settings.state, expected)
            XCTAssertTrue(settings.canSyncNow)
            XCTAssertNil(session.model.errorMessage)
            let durable = try await fixture.reopen(adopts ? replacement : fixture.original)
            XCTAssertEqual(durable.snips.map(\.content), adopts ? ["Replacement source"] : ["Original source"])
        }
    }

    private func observeStatusGuardSnapshot(_ model: IOSAppModel) -> OfflineSignal {
        let changed = OfflineSignal()
        withObservationTracking { _ = model.snips } onChange: { changed.fire() }
        return changed
    }

    private func withStatusGuard(_ check: (StatusGuardFixture) async throws -> Void) async throws {
        let fixture = try await StatusGuardFixture.make()
        do {
            try await check(fixture)
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }
}

// Only the first public snapshot read pauses; every operation still uses the real durable store.
private actor ReplacementSnapshotGuardLibrary: SnipLibrary {
    private let base: SwiftDataSnipLibrary
    private var nextSnapshotGate: StatusGuardGate?
    private var snapshotReads = 0

    init(base: SwiftDataSnipLibrary, gate: StatusGuardGate) {
        self.base = base
        nextSnapshotGate = gate
    }

    func snapshotReadCount() -> Int { snapshotReads }

    func snapshot(sortedBy sortMode: SnipSortMode) async -> SnipLibrarySnapshot {
        snapshotReads += 1
        let gate = nextSnapshotGate
        nextSnapshotGate = nil
        await gate?.suspend()
        return await base.snapshot(sortedBy: sortMode)
    }

    func checkedSnapshot(sortedBy sortMode: SnipSortMode) async throws -> SnipLibrarySnapshot {
        try await base.checkedSnapshot(sortedBy: sortMode)
    }

    func perform(_ command: SnipLibraryCommand, sortedBy sortMode: SnipSortMode) async throws -> SnipLibraryUpdate {
        try await base.perform(command, sortedBy: sortMode)
    }

    func transferSnapshot(revision: UInt64) async throws -> SnipLibraryTransferSnapshot {
        try await base.transferSnapshot(revision: revision)
    }

    func previewTransferSnapshot(revision: UInt64) async throws -> SnipLibraryTransferSnapshot {
        try await base.previewTransferSnapshot(revision: revision)
    }

    func mergeTransferSnapshot(_ source: SnipLibraryTransferSnapshot, transitionID: UUID,
                               expectedTargetDigest: Data?) async throws -> SnipLibraryTransferResult {
        try await base.mergeTransferSnapshot(source, transitionID: transitionID, expectedTargetDigest: expectedTargetDigest)
    }

    func previewImport(_ source: SnipLibraryTransferSnapshot, transitionID: UUID) async throws -> SnipImportPreview {
        try await base.previewImport(source, transitionID: transitionID)
    }

    func applyImport(_ preview: SnipImportPreview) async throws -> SnipImportResult {
        try await base.applyImport(preview)
    }

    func recoverySnapshot(in scope: SnipRecoveryScope) async throws -> SnipRecoverySnapshot {
        try await base.recoverySnapshot(in: scope)
    }

    func resolveRecovery(_ id: UUID, in scope: SnipRecoveryScope,
                         choice: SnipRecoveryChoice) async throws -> SnipLibrarySnapshot {
        try await base.resolveRecovery(id, in: scope, choice: choice)
    }

    func resolveRecovery(_ id: UUID, in scope: SnipRecoveryScope, choice: SnipRecoveryChoice,
                         expectation: SnipRecoveryExpectation?) async throws -> SnipLibrarySnapshot {
        try await base.resolveRecovery(id, in: scope, choice: choice, expectation: expectation)
    }

    func archive() async throws -> SnipLibraryArchive {
        try await base.archive()
    }
}

extension IOSOfflineLocalFeedbackTests {
    func testWaitingLoadSurvivesReplacementSnapshotAndCurrentStatusWindows() async throws {
        try await withStatusGuard { fixture in
            let model = try XCTUnwrap(fixture.model)
            let oldStatus = fixture.gate()
            let replacementRead = fixture.gate()
            let currentStatus = fixture.gate()
            let id = StatusGuardFixture.attachmentID
            await fixture.handler.enqueueStates(.success([id: .failed]), gate: oldStatus)
            await fixture.handler.enqueueStates(.success([id: .available]), gate: currentStatus)
            let oldLoad = fixture.start { await model.load(); return true }
            guard await fixture.ready(oldStatus.entered, "old load reached its first handler state read") else { return }
            let oldCallReturned = await fixture.handler.idleSignal()
            let currentEntry = await fixture.handler.entry(.states, number: 2)
            let replacement = try await fixture.replacement()
            let forwarding = ReplacementSnapshotGuardLibrary(base: replacement.library, gate: replacementRead)
            let replacing = fixture.start {
                await model.replaceLibrary(forwarding, recoveryScope: nil)
                return true
            }
            guard await fixture.ready(replacementRead.entered, "real replacement reached snapshot(sortedBy:)") else { return }
            let readsWhileHeld = await forwarding.snapshotReadCount()
            XCTAssertEqual(readsWhileHeld, 1)
            XCTAssertEqual(model.snips.map(\.content), ["Original source"])
            XCTAssertTrue(oldStatus.isHeld)
            XCTAssertTrue(replacementRead.isHeld)

            oldStatus.release()
            guard await fixture.ready(oldCallReturned, "old external state call returned during local replacement") else { return }
            let finishedDuringLocalRead = await oldLoad.finished.wait(for: .seconds(2))
            XCTAssertFalse(finishedDuringLocalRead,
                           "An old load must remain waiting while replacement's local snapshot is held")
            XCTAssertTrue(replacementRead.isHeld)
            XCTAssertFalse(currentEntry.isSet, "Current status cannot start before replacement's local snapshot returns")
            let beforeAdoption = await fixture.handler.snapshotCounts()
            XCTAssertEqual(beforeAdoption.entries[.states], 1)

            replacementRead.release()
            guard await fixture.ready(currentEntry, "replacement reached its second handler state read"),
                  await fixture.ready(currentStatus.entered, "new source status read held") else { return }
            XCTAssertEqual(model.snips.map(\.content), ["Replacement source"])
            let finishedDuringCurrentStatus = await oldLoad.finished.wait(for: .milliseconds(100))
            XCTAssertFalse(finishedDuringCurrentStatus,
                           "An old load must join replacement's current attachment knowledge")
            let replacementFinishedEarly = await replacing.finished.wait(for: .milliseconds(100))
            XCTAssertFalse(replacementFinishedEarly)
            XCTAssertTrue(currentStatus.isHeld)

            currentStatus.release()
            guard await fixture.ready(oldLoad.finished, "waiting load completed with replacement status"),
                  await fixture.ready(replacing.finished, "replacement completed with current status") else { return }
            XCTAssertEqual(model.snips.map(\.id), [StatusGuardFixture.snipID])
            XCTAssertEqual(model.snips.map(\.content), ["Replacement source"])
            XCTAssertTrue(model.isCloudSyncActive)
            XCTAssertEqual(model.attachmentTransferState(for: id), .available)
            XCTAssertNil(model.attachmentURL(for: id), "Remote status alone must not verify local attachment bytes")
            let durable = try await fixture.reopen(replacement)
            XCTAssertEqual(durable.snips.map(\.id), [StatusGuardFixture.snipID])
            XCTAssertEqual(durable.snips.map(\.content), ["Replacement source"])
            let actualFile = try XCTUnwrap(durable.attachmentURLs[id])
            XCTAssertEqual(try Data(contentsOf: actualFile), Data("new!".utf8))
            let reads = await forwarding.snapshotReadCount()
            XCTAssertEqual(reads, 1, "The controlled read belongs to the actual replacement operation")
            let calls = await fixture.handler.snapshotCounts()
            XCTAssertEqual(calls.entries[.states], 2)
            XCTAssertEqual(calls.maximumActiveStatus, 1)
        }
    }
}
