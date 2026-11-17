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
    private var ownedModel: IOSAppModel?
    private weak var modelLifetime: IOSAppModel?
    private var libraryLifetimes: [FixtureWeakResource<SwiftDataSnipLibrary>] = []
    var model: IOSAppModel { ownedModel! }
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
        ownedModel = IOSAppModel(library: assembly.library, userActions: assembly.userActions,
                            userActionsFactory: assembly.userActionsFactory,
                            initialSnapshot: snapshot, cloudSyncHandler: handler,
                            haptics: IOSHapticFeedback(defaults: defaults, player: RecordingHapticPlayer()))
        modelLifetime = ownedModel
        libraryLifetimes.append(FixtureWeakResource(library))
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
            // Store container closure is not observable through the public library API.
            NSLog("OfflineFixture retained failed setup store root: %@", root.path)
            throw error
        }
    }

    func reopenSnapshot() async throws -> SnipLibrarySnapshot {
        let reader = try SwiftDataSnipLibrary(storeURL: storeURL)
        libraryLifetimes.append(FixtureWeakResource(reader))
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
                work.removeAll()
                ownedModel = nil
                XCTAssertNil(modelLifetime, "Offline fixture still has a live model owner")
                XCTAssertTrue(libraryLifetimes.allSatisfy { $0.value == nil },
                              "Offline fixture still has a live store or reader")
                composer.draftStore.flushText()
                defaults.removePersistentDomain(forName: suite)
                UIPasteboard.remove(withName: boardName)
                // SwiftData can defer container cleanup after library deallocation; retain this root.
                NSLog("OfflineFixture retained store root: %@", root.path)
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
    static let secondAttachmentID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    static let snipID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    final class Store {
        private var ownedLibrary: SwiftDataSnipLibrary?
        private weak var lifetime: SwiftDataSnipLibrary?
        let url: URL
        let snapshot: SnipLibrarySnapshot
        var library: SwiftDataSnipLibrary { ownedLibrary! }
        var isReleased: Bool { lifetime == nil }

        init(library: SwiftDataSnipLibrary, url: URL, snapshot: SnipLibrarySnapshot) {
            ownedLibrary = library
            lifetime = library
            self.url = url
            self.snapshot = snapshot
        }

        func releaseOwnership() { ownedLibrary = nil }
    }
    let root: URL
    let original: Store
    let originalPrepared: URL
    let replacementPrepared: URL
    let handler: StatusGuardHandler
    private var ownedModel: IOSAppModel?
    private var modelLifetimes: [FixtureWeakResource<IOSAppModel>] = []
    private var readerLifetimes: [FixtureWeakResource<SwiftDataSnipLibrary>] = []
    private var stores: [Store] = []
    var model: IOSAppModel? {
        get { ownedModel }
        set {
            ownedModel = newValue
            if let newValue { modelLifetimes.append(FixtureWeakResource(newValue)) }
        }
    }
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
        stores.append(original)
    }
    static func make(twoAttachments: Bool = false) async throws -> StatusGuardFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StatusGuards-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let oldFile = root.appendingPathComponent("verified-old.txt")
            let newFile = root.appendingPathComponent("verified-new.txt")
            try Data("old!".utf8).write(to: oldFile)
            try Data("new!".utf8).write(to: newFile)
            if twoAttachments { try Data("two!".utf8).write(to: root.appendingPathComponent("verified-second.txt")) }
            let original = try await makeStore(root: root, name: "original", content: "Original source",
                                               bytes: "old!", twoAttachments: twoAttachments)
            return StatusGuardFixture(root: root, original: original, oldFile: oldFile, newFile: newFile)
        } catch {
            // Keep failed setup storage rather than unlink a potentially live container.
            NSLog("StatusGuardFixture retained failed setup store root: %@", root.path)
            throw error
        }
    }
    private static func makeStore(root: URL, name: String, content: String, bytes: String,
                                  twoAttachments: Bool = false) async throws -> Store {
        let url = root.appendingPathComponent(name).appendingPathComponent("snips.store")
        let library = try SwiftDataSnipLibrary(storeURL: url)
        let attachment = try testAttachment(id: attachmentID, fileName: "payload.txt", byteCount: 4)
        var attachments = [attachment]
        var data = [attachmentID: Data(bytes.utf8)]
        if twoAttachments {
            attachments.append(try testAttachment(id: secondAttachmentID, fileName: "second.txt", byteCount: 4))
            data[secondAttachmentID] = Data("two!".utf8)
        }
        let snip = Snip(id: snipID, content: content, origin: .quickEntry, attachments: attachments)
        _ = try await library.mergeTransferSnapshot(SnipLibraryTransferSnapshot(
            revision: 0, snips: [snip], lists: [.inbox], attachmentData: data
        ), transitionID: UUID(), expectedTargetDigest: nil)
        let snapshot = try await library.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(snapshot.snips.map(\.id), [snipID], "Fixture import must retain the supplied ID")
        XCTAssertEqual(snapshot.snips.map(\.content), [content])
        let local = try XCTUnwrap(snapshot.attachmentURLs[attachmentID])
        XCTAssertEqual(try Data(contentsOf: local), Data(bytes.utf8))
        return Store(library: library, url: url, snapshot: snapshot)
    }
    func replacement() async throws -> Store {
        let store = try await Self.makeStore(root: root, name: "replacement", content: "Replacement source", bytes: "new!")
        stores.append(store)
        return store
    }
    func reopen(_ store: Store) async throws -> SnipLibrarySnapshot {
        let reader = try SwiftDataSnipLibrary(storeURL: store.url)
        readerLifetimes.append(FixtureWeakResource(reader))
        return try await reader.checkedSnapshot(sortedBy: .manual)
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
                work.append(draining)
                let done = await draining.finished.wait(for: deadline - ContinuousClock.now)
                XCTAssertTrue(done, "Guard cleanup could not drain status work")
                if done { await draining.task?.value }
                else { draining.task?.cancel(); settled = false }
            }
            let idle = await handler.idleSignal()
            let done = await idle.wait(for: deadline - ContinuousClock.now)
            XCTAssertTrue(done, "Guard cleanup left an external handler call suspended")
            guard settled && done else {
                NSLog("StatusGuardFixture retained live ownership and store root: %@", root.path)
                return
            }
            work.removeAll()
            model = nil
            stores.forEach { $0.releaseOwnership() }
            XCTAssertTrue(modelLifetimes.allSatisfy { $0.value == nil },
                          "A model or IOSAppSession still owns fixture state")
            XCTAssertTrue(stores.allSatisfy(\.isReleased),
                          "A store, forwarding library or sync session is still live")
            XCTAssertTrue(readerLifetimes.allSatisfy { $0.value == nil }, "A fixture reader is still live")
            // SwiftData's deferred container cleanup has no public completion receipt.
            NSLog("StatusGuardFixture retained store root: %@", root.path)
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

@MainActor
private final class FixtureWeakResource<Resource: AnyObject> {
    weak var value: Resource?
    init(_ value: Resource) { self.value = value }
}

private final class StagedCopyObserver: FileManager, @unchecked Sendable {
    private let boardName: String
    private let lock = NSLock()
    private var copiedDestinations: [Int: URL] = [:]
    var destinations: [Int: URL] { lock.withLock { copiedDestinations } }

    init(boardName: String) {
        self.boardName = boardName
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        guard let ordinal = Int(dstURL.deletingLastPathComponent().lastPathComponent) else {
            NSLog("OFFLINE-COPY-DIAG phase=after-copyItem board=%@ ordinal=unrecognized path=%@",
                  boardName, dstURL.path)
            return
        }
        lock.withLock { copiedDestinations[ordinal] = dstURL }
        Self.log([ordinal: dstURL], phase: "after-copyItem", context: "board=\(boardName)", ordinals: [ordinal])
    }

    static func log(_ destinations: [Int: URL], phase: String, context: String, ordinals: [Int] = [1, 2]) {
        let observations = ordinals.map { ordinal in
            guard let url = destinations[ordinal] else { return "ordinal=\(ordinal) destination=unobserved" }
            let path = url.path
            let label = "ordinal=\(ordinal) path=\(path)"
            let files = FileManager.default
            do {
                let attributes = try files.attributesOfItem(atPath: path)
                let size = (attributes[.size] as? NSNumber)?.stringValue ?? "<unavailable>"
                return "\(label) stat=ok size=\(size) readable=\(files.isReadableFile(atPath: path))"
            } catch {
                let error = error as NSError
                return "\(label) stat-error=\(error.domain):\(error.code) size=<unavailable> readable=<unavailable>"
            }
        }
        NSLog("OFFLINE-COPY-DIAG phase=%@ %@ %@", phase, context, observations.joined(separator: " | "))
    }
}

@MainActor
private final class CapturedCopyBoard: IOSPasteboardWriting {
    let suite = "CapturedCopy.\(UUID())"
    let name = UIPasteboard.Name("CapturedCopy.\(UUID())")
    let board: UIPasteboard
    let feedback: IOSHapticFeedback
    let diagnosticStagingRoot: URL
    private let defaults: UserDefaults
    private let system: IOSSystemPasteboard
    private let stagingObserver: StagedCopyObserver?
    private(set) var writes = 0
    var observedStagingDestinations: [Int: URL] { stagingObserver?.destinations ?? [:] }

    init(root: URL, observeStagingCopies: Bool = false) throws {
        diagnosticStagingRoot = root.appendingPathComponent("copy-staging")
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        board = try XCTUnwrap(UIPasteboard(name: name, create: true))
        let observer = observeStagingCopies ? StagedCopyObserver(boardName: name.rawValue) : nil
        stagingObserver = observer
        let fileManager = (observer as FileManager?) ?? .default
        system = IOSSystemPasteboard(pasteboard: board, stagingRoot: diagnosticStagingRoot, fileManager: fileManager)
        feedback = IOSHapticFeedback(defaults: defaults, player: RecordingHapticPlayer())
        feedback.isActive = true
    }

    func write(_ items: [IOSCopyItem]) -> Bool {
        if stagingObserver == nil {
            CopiedFileBytes.logFileState(stagingRoot: diagnosticStagingRoot, phase: "write-before",
                                        context: "board=\(name.rawValue) writes=\(writes)")
        }
        let written = system.write(items)
        if written { writes += 1 }
        if let stagingObserver {
            StagedCopyObserver.log(stagingObserver.destinations, phase: "writer-return",
                                   context: "board=\(name.rawValue) writes=\(writes) success=\(written)")
        } else if written {
            CopiedFileBytes.logFileState(stagingRoot: diagnosticStagingRoot, phase: "write-after",
                                        context: "board=\(name.rawValue) writes=\(writes)")
        }
        return written
    }

    func diagnosticContext(for provider: NSItemProvider, index: Int, selectedType: String) -> String {
        "board=\(name.rawValue) index=\(index) object=\(ObjectIdentifier(provider)) class=\(String(reflecting: type(of: provider))) types=\(provider.registeredTypeIdentifiers) selected=\(selectedType) suggestedName=\(provider.suggestedName ?? "<nil>")"
    }

    func close() {
        UIPasteboard.remove(withName: name)
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class CopiedFileBytes: @unchecked Sendable {
    let loaded = OfflineSignal()
    private let lock = NSLock()
    private var stored: Data?
    var data: Data? { lock.withLock { stored } }

    func read(_ url: URL?, providerError: Error? = nil, diagnosticContext: String? = nil,
              stagedDestinations: [Int: URL] = [:]) {
        var readError: NSError?
        let data = url.flatMap {
            do { return try Data(contentsOf: $0) }
            catch { readError = error as NSError; return nil }
        }
        lock.withLock { stored = data }
        loaded.fire()
        guard let diagnosticContext else { return }
        NSLog("OFFLINE-COPY-DIAG phase=callback-after-read-and-loaded-signal %@ callbackURL=%@ providerError=%@ dataReadError=%@ readAttempted=%@ dataBytes=%@",
              diagnosticContext, url?.absoluteString ?? "<nil>",
              providerError.map { String(describing: $0 as NSError) } ?? "<nil>",
              readError.map { String(describing: $0) } ?? "<nil>",
              url == nil ? "no URL" : "yes", data.map { String($0.count) } ?? "<nil>")
        if data == nil || providerError != nil {
            StagedCopyObserver.log(stagedDestinations, phase: "failed-callback-after-read-and-signal",
                                   context: diagnosticContext)
        }
    }

    static func logFileState(stagingRoot: URL, phase: String, context: String, callbackURL: URL? = nil) {
        func logStat(_ url: URL, role: String) -> FileAttributeType? {
            guard url.isFileURL else {
                NSLog("OFFLINE-COPY-DIAG phase=%@ %@ role=%@ url=%@ stat=not-attempted-nonfile",
                      phase, context, role, url.absoluteString)
                return nil
            }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let type = attributes[.type] as? FileAttributeType
                NSLog("OFFLINE-COPY-DIAG phase=%@ %@ role=%@ url=%@ stat=ok type=%@ size=%@",
                      phase, context, role, url.absoluteString, type?.rawValue ?? "<unavailable>",
                      String(describing: attributes[.size] ?? "<unavailable>"))
                return type
            } catch {
                NSLog("OFFLINE-COPY-DIAG phase=%@ %@ role=%@ url=%@ stat-error=%@",
                      phase, context, role, url.absoluteString, error as NSError)
                return nil
            }
        }
        if let callbackURL { _ = logStat(callbackURL, role: "actual-callback-url") }
        guard logStat(stagingRoot, role: "owned-staging-root") == .typeDirectory else {
            NSLog("OFFLINE-COPY-DIAG phase=%@ %@ enumeration=not-attempted-root-directory-unconfirmed", phase, context)
            return
        }
        guard let entries = FileManager.default.enumerator(
            at: stagingRoot, includingPropertiesForKeys: nil, options: [],
            errorHandler: { url, error in
                NSLog("OFFLINE-COPY-DIAG phase=%@ %@ enumeration-error url=%@ error=%@",
                      phase, context, url.absoluteString, error as NSError)
                return false
            }
        ) else {
            NSLog("OFFLINE-COPY-DIAG phase=%@ %@ enumeration=unavailable-completeness-unknown", phase, context)
            return
        }
        let entryLimit = 24
        let depthLimit = 3
        let rootPath = stagingRoot.standardizedFileURL.path
        var count = 0
        var reachedEnd = false
        while count < entryLimit {
            guard let entry = entries.nextObject() else { reachedEnd = true; break }
            count += 1
            guard let url = entry as? URL else {
                entries.skipDescendants()
                NSLog("OFFLINE-COPY-DIAG phase=%@ %@ enumeration-entry=unexpected-type %@", phase, context,
                      String(reflecting: type(of: entry)))
                continue
            }
            guard url.standardizedFileURL.path.hasPrefix(rootPath + "/") else {
                entries.skipDescendants()
                NSLog("OFFLINE-COPY-DIAG phase=%@ %@ enumeration-entry=outside-owned-root-skipped url=%@",
                      phase, context, url.absoluteString)
                continue
            }
            let type = logStat(url, role: "owned-staging-entry depth=\(entries.level)")
            if type != .typeDirectory || entries.level >= depthLimit {
                entries.skipDescendants()
                if type == .typeDirectory {
                    NSLog("OFFLINE-COPY-DIAG phase=%@ %@ depth-limit=%ld descendants-not-inspected url=%@",
                          phase, context, depthLimit, url.absoluteString)
                }
            }
        }
        NSLog("OFFLINE-COPY-DIAG phase=%@ %@ enumeration-yielded=%ld limit=%ld ended=%@ completeness=not-guaranteed-errors-or-depth-skips-or-cap; snapshot-not-atomic",
              phase, context, count, entryLimit, reachedEnd ? "yes" : "no-cap-reached")
    }
}

extension IOSOfflineLocalFeedbackTests {
    func testCapturedCopyWritesOriginalBytesAfterDurableDeletionWithoutResurrection() async throws {
        try await checkCapturedCopyAfterDeletion(attachmentsOnly: false)
    }

    func testCapturedAttachmentCopyPreservesNewerDeletionFeedbackAndWritesOnce() async throws {
        try await checkCapturedCopyAfterDeletion(attachmentsOnly: true)
    }

    private func checkCapturedCopyAfterDeletion(attachmentsOnly: Bool) async throws {
        try await withStatusGuard { fixture in
            let board = try CapturedCopyBoard(root: fixture.root)
            defer { board.close() }
            let model = IOSAppModel(library: fixture.original.library, initialSnapshot: fixture.original.snapshot,
                                    cloudSyncHandler: fixture.handler, haptics: board.feedback)
            fixture.model = model
            let id = StatusGuardFixture.attachmentID
            await fixture.handler.set(mode: true, states: [id: .available])
            let loading = fixture.start { await model.load(); return true }
            guard await fixture.ready(loading.finished, "captured-copy initial attachment knowledge") else { return }
            let snip = try XCTUnwrap(model.snips.first)
            model.selectSnips([StatusGuardFixture.snipID])
            XCTAssertEqual(board.feedback.event?.kind, .selection)
            let prepare = fixture.gate()
            let deletionStatus = fixture.gate()
            await fixture.handler.enqueuePrepare(fixture.originalPrepared, gate: prepare)
            let coordinator = IOSCopyShareCoordinator(pasteboard: board)
            let copying = fixture.start {
                if attachmentsOnly { return await coordinator.copyAttachments(snips: [snip], model: model) }
                return await coordinator.copy(snips: [snip], model: model)
            }
            guard await fixture.ready(prepare.entered, "original captured copy prepare held") else { return }
            await fixture.handler.set(mode: true, states: [:])
            await fixture.handler.enqueueStates(.success([:]), gate: deletionStatus)
            let deleting = fixture.start { await model.deleteSnip(id: StatusGuardFixture.snipID) }
            guard await fixture.completed(deleting, "Deletion must commit while captured copy is pending"),
                  await fixture.ready(deletionStatus.entered, "deletion status remains held") else { return }
            XCTAssertEqual(deleting.result, true)
            let deleted = try await fixture.reopen(fixture.original)
            XCTAssertTrue(deleted.snips.isEmpty)
            XCTAssertTrue(model.snips.isEmpty)
            XCTAssertEqual(board.feedback.event?.kind, .deleted)
            let deletionFeedback = board.feedback.event
            let deletionToast = model.toast
            XCTAssertEqual(deletionToast?.action, .undoDelete)
            prepare.release()
            guard await fixture.completed(copying, "An admitted same-source copy must finish its captured payload") else { return }
            XCTAssertEqual(copying.result, true)
            XCTAssertEqual(board.writes, 1, "Keep the existing haptic test's one-write oracle")
            XCTAssertNil(coordinator.unavailableFilesNotice)
            XCTAssertTrue(deletionStatus.isHeld)
            XCTAssertTrue(model.snips.isEmpty)
            XCTAssertNil(model.attachmentURL(for: id))
            XCTAssertNil(model.usableAttachmentURL(for: id))
            XCTAssertEqual(model.attachmentTransferState(for: id), .waiting,
                           "A removed preparation must not restore its group's old available state")
            XCTAssertEqual(board.feedback.event, deletionFeedback)
            XCTAssertEqual(model.toast?.id, deletionToast?.id)
            XCTAssertEqual(model.toast?.action, .undoDelete)
            let afterCopy = try await fixture.reopen(fixture.original)
            XCTAssertTrue(afterCopy.snips.isEmpty, "Copy must not restore content or Done rows")
            if board.writes == 1 {
                XCTAssertEqual(board.board.itemProviders.count, attachmentsOnly ? 1 : 2)
                if !attachmentsOnly { XCTAssertEqual(board.board.string, "Original source") }
                let provider = try XCTUnwrap(board.board.itemProviders.last)
                let type = try XCTUnwrap(provider.registeredTypeIdentifiers.first)
                let bytes = CopiedFileBytes()
                _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in bytes.read(url) }
                guard await fixture.ready(bytes.loaded, "actual copied file representation loaded") else { return }
                XCTAssertEqual(bytes.data, Data("old!".utf8))
            }
            deletionStatus.release()
        }
    }

    func testDeletedCapturedCopyReturnsOnlyItsOriginalPreparedURLWithoutPublishingState() async throws {
        try await checkRemovedPrepare(use: .copy, returnsCapturedBytes: true)
    }

    func testDeletedAttachmentCannotFinishPreviewOpenOrExport() async throws {
        for use in [SyncedAttachmentUse.preview, .open, .export] {
            try await checkRemovedPrepare(use: use, returnsCapturedBytes: false)
        }
    }

    private func checkRemovedPrepare(use: SyncedAttachmentUse, returnsCapturedBytes: Bool) async throws {
        try await withStatusGuard { fixture in
            let model = try XCTUnwrap(fixture.model)
            let id = StatusGuardFixture.attachmentID
            await fixture.handler.set(mode: true, states: [id: .available])
            let loading = fixture.start { await model.load(); return true }
            guard await fixture.ready(loading.finished, "removed prepare initial knowledge") else { return }
            let prepare = fixture.gate()
            let deletionStatus = fixture.gate()
            await fixture.handler.enqueuePrepare(fixture.originalPrepared, gate: prepare)
            var prepared: URL?
            let preparing = fixture.start {
                prepared = await model.prepareAttachment(id, for: use)
                return prepared != nil
            }
            guard await fixture.ready(prepare.entered, "known attachment admitted before deletion") else { return }
            await fixture.handler.set(mode: true, states: [:])
            await fixture.handler.enqueueStates(.success([:]), gate: deletionStatus)
            let deleting = fixture.start { await model.deleteSnip(id: StatusGuardFixture.snipID) }
            guard await fixture.completed(deleting, "Known attachment's snip deleted durably"),
                  await fixture.ready(deletionStatus.entered, "removed prepare status held") else { return }
            XCTAssertEqual(deleting.result, true)
            prepare.release()
            guard await fixture.completed(preparing, "Removed prepare returned without waiting for status") else { return }
            XCTAssertEqual(prepared, returnsCapturedBytes ? fixture.originalPrepared : nil)
            if returnsCapturedBytes {
                let url = try XCTUnwrap(prepared)
                XCTAssertEqual(try Data(contentsOf: url), Data("old!".utf8))
            }
            XCTAssertNil(model.attachmentURL(for: id))
            XCTAssertNil(model.usableAttachmentURL(for: id))
            XCTAssertEqual(model.attachmentTransferState(for: id), .waiting)
            XCTAssertTrue(model.snips.isEmpty)
            let durable = try await fixture.reopen(fixture.original)
            XCTAssertTrue(durable.snips.isEmpty)
            let board = try CapturedCopyBoard(root: fixture.root)
            defer { board.close() }
            let coordinator = IOSCopyShareCoordinator(pasteboard: board)
            let later = fixture.start {
                await coordinator.copy(snips: fixture.original.snapshot.snips, model: model)
            }
            guard await fixture.completed(later, "A later copy cannot capture an already deleted snip") else { return }
            XCTAssertEqual(later.result, false)
            XCTAssertEqual(board.writes, 0)
            XCTAssertNil(model.attachmentURL(for: id))
            XCTAssertTrue(deletionStatus.isHeld)
            deletionStatus.release()
        }
    }

    func testCapturedCopyRejectsRemovalFromAnExistingSnip() async throws {
        try await checkInvalidatedCapturedCopy(change: .removeAttachment)
    }

    func testCapturedCopyRejectsAReplacedSourceWithIdenticalAttachmentMetadata() async throws {
        try await checkInvalidatedCapturedCopy(change: .replaceSource)
    }

    func testCapturedCopyRejectsFileRevisionInvalidatedByCacheClear() async throws {
        try await checkInvalidatedCapturedCopy(change: .clearFiles)
    }

    private enum CapturedCopyChange { case removeAttachment, replaceSource, clearFiles }

    private func checkInvalidatedCapturedCopy(change: CapturedCopyChange) async throws {
        try await withStatusGuard { fixture in
            let model = try XCTUnwrap(fixture.model)
            let id = StatusGuardFixture.attachmentID
            let loading = fixture.start { await model.load(); return true }
            guard await fixture.ready(loading.finished, "captured-copy rejection initial knowledge") else { return }
            let snip = try XCTUnwrap(model.snips.first)
            let gate = fixture.gate()
            await fixture.handler.enqueuePrepare(fixture.originalPrepared, gate: gate)
            var prepared: URL?
            let preparing = fixture.start {
                prepared = await model.prepareAttachment(id, for: .copy)
                return prepared != nil
            }
            guard await fixture.ready(gate.entered, "copy prepare admitted before invalidation") else { return }
            var replacement: StatusGuardFixture.Store?
            let changing = fixture.start {
                switch change {
                case .removeAttachment:
                    await fixture.handler.set(mode: true, states: [:])
                    return await model.editSnip(snip, content: "Edited without attachment", attachmentEdits: [])
                case .replaceSource:
                    let store: StatusGuardFixture.Store
                    do { store = try await fixture.replacement() }
                    catch { XCTFail("Replacement setup failed: \(error)"); return false }
                    replacement = store
                    await model.replaceLibrary(store.library, recoveryScope: nil)
                    return true
                case .clearFiles:
                    await model.clearDownloadedFiles()
                    return true
                }
            }
            guard await fixture.completed(changing, "Invalidation must finish independently of old copy") else { return }
            XCTAssertEqual(changing.result, true)
            gate.release()
            guard await fixture.completed(preparing, "Invalidated copy must return") else { return }
            XCTAssertNil(prepared)
            XCTAssertNil(model.attachmentURL(for: id))
            XCTAssertEqual(model.attachmentTransferState(for: id), .waiting)
            XCTAssertNil(model.errorMessage)
            let durable = try await fixture.reopen(replacement ?? fixture.original)
            switch change {
            case .removeAttachment:
                XCTAssertEqual(durable.snips.map(\.content), ["Edited without attachment"])
                XCTAssertEqual(durable.snips.first?.attachments.count, 0)
            case .replaceSource: XCTAssertEqual(durable.snips.map(\.content), ["Replacement source"])
            case .clearFiles: XCTAssertEqual(durable.snips.map(\.content), ["Original source"])
            }
            XCTAssertTrue(durable.snips.allSatisfy { !$0.isDone })
        }
    }
}

extension IOSOfflineLocalFeedbackTests {
    func testMultiAttachmentCopyRevalidatesSourceAfterLaterPreparation() async throws {
        try await checkLateCapturedCopyChange(.source)
    }

    func testMultiAttachmentCopyRevalidatesFilesAfterLaterPreparation() async throws {
        try await checkLateCapturedCopyChange(.files)
    }

    func testMultiAttachmentCopyRevalidatesEarlierAttachmentIdentity() async throws {
        try await checkLateCapturedCopyChange(.identity)
    }

    func testMultiAttachmentCopyCannotReviveChangedIdentityAfterDeletion() async throws {
        try await checkLateCapturedCopyChange(.identityThenDeletion)
    }

    func testCancelledMultiAttachmentCopyNeverWritesCapturedBytes() async throws {
        try await checkLateCapturedCopyChange(.cancel)
    }

    func testExportNeverUsesDeletedCapturedCopyBytes() async throws {
        try await checkLateCapturedCopyChange(.exportDeletion)
    }

    func testMultiAttachmentCopyAllowsOrdinarySameSourceDeletionOnly() async throws {
        try await checkLateCapturedCopyChange(.ordinaryDeletion)
    }

    private enum LateCopyChange: Equatable { case source, files, identity, identityThenDeletion, cancel, exportDeletion, ordinaryDeletion }

    private func checkLateCapturedCopyChange(_ change: LateCopyChange) async throws {
        let fixture = try await StatusGuardFixture.make(twoAttachments: true)
        do {
            try await exerciseLateCapturedCopyChange(change, fixture: fixture)
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    private func exerciseLateCapturedCopyChange(_ change: LateCopyChange, fixture: StatusGuardFixture) async throws {
        let board = try CapturedCopyBoard(root: fixture.root, observeStagingCopies: change == .ordinaryDeletion)
        defer { board.close() }
        board.board.string = "Keep this clipboard until a valid copy finishes"
        let model = IOSAppModel(library: fixture.original.library, initialSnapshot: fixture.original.snapshot,
                                cloudSyncHandler: fixture.handler, haptics: board.feedback)
        fixture.model = model
        let firstID = StatusGuardFixture.attachmentID
        let secondID = StatusGuardFixture.secondAttachmentID
        await fixture.handler.set(mode: true, states: [firstID: .waiting, secondID: .waiting])
        let loading = fixture.start { await model.load(); return true }
        guard await fixture.ready(loading.finished, "multi-copy initial attachment knowledge") else { return }
        let snip = try XCTUnwrap(model.snips.first)
        XCTAssertEqual(snip.attachments.map(\.id), [firstID, secondID])
        let first = fixture.gate()
        let second = fixture.gate()
        let secondURL = fixture.root.appendingPathComponent("verified-second.txt")
        await fixture.handler.enqueuePrepare(fixture.originalPrepared, gate: first)
        await fixture.handler.enqueuePrepare(secondURL, gate: second)
        let coordinator = IOSCopyShareCoordinator(pasteboard: board)
        let copying = fixture.start {
            if change == .exportDeletion {
                await coordinator.share(snips: [snip], model: model)
                return coordinator.shareRequest != nil
            }
            return await coordinator.copy(snips: [snip], model: model)
        }
        guard await fixture.ready(first.entered, "first captured prepare admitted") else { return }
        first.release()
        guard await fixture.ready(second.entered, "later prepare held after first URL was captured") else { return }
        XCTAssertEqual(model.usableAttachmentURL(for: firstID), fixture.originalPrepared)
        let clearedStatus = fixture.gate()
        if change == .files {
            await fixture.handler.enqueueStates(.success([firstID: .waiting, secondID: .waiting]), gate: clearedStatus)
        }
        var replacement: StatusGuardFixture.Store?
        let changing = fixture.start {
            switch change {
            case .source:
                do {
                    let store = try await fixture.replacement()
                    replacement = store
                    await model.replaceLibrary(store.library, recoveryScope: nil)
                    return true
                } catch { XCTFail("Late replacement setup failed: \(error)"); return false }
            case .files:
                await model.clearDownloadedFiles()
                return true
            case .identity, .identityThenDeletion:
                let changedFile = fixture.root.appendingPathComponent("changed.txt")
                do { try Data("changed!".utf8).write(to: changedFile) }
                catch { XCTFail("Changed attachment setup failed: \(error)"); return false }
                let edited = await model.editSnip(snip, content: "Edited during captured copy", attachmentEdits: [
                    .replacement(attachmentID: firstID, sourceURL: changedFile),
                    .existing(attachmentID: secondID),
                ])
                guard edited else { return false }
                if change == .identityThenDeletion {
                    await fixture.handler.set(mode: true, states: [:])
                    return await model.deleteSnip(id: StatusGuardFixture.snipID)
                }
                return true
            case .cancel:
                copying.task?.cancel()
                return true
            case .exportDeletion, .ordinaryDeletion:
                await fixture.handler.set(mode: true, states: [:])
                return await model.deleteSnip(id: StatusGuardFixture.snipID)
            }
        }
        if change == .files {
            guard await fixture.ready(clearedStatus.entered, "confirmed cache clear awaits status") else { return }
            let clearedTooEarly = await changing.finished.wait(for: .milliseconds(100))
            XCTAssertFalse(clearedTooEarly)
        } else {
            guard await fixture.completed(changing, "Late invalidation must finish while the second prepare is held") else { return }
            XCTAssertEqual(changing.result, true)
        }
        XCTAssertTrue(second.isHeld)
        second.release()
        guard await fixture.completed(copying, "Captured operation returned after the later prepare") else { return }
        if change == .files {
            XCTAssertTrue(clearedStatus.isHeld)
            clearedStatus.release()
            guard await fixture.completed(changing, "Cache clear completed after its status release") else { return }
            XCTAssertEqual(changing.result, true)
        }
        if change == .ordinaryDeletion {
            XCTAssertEqual(copying.result, true)
            XCTAssertEqual(board.writes, 1)
            XCTAssertEqual(board.board.string, "Original source")
            XCTAssertEqual(board.feedback.event?.kind, .deleted)
            XCTAssertEqual(model.toast?.action, .undoDelete)
            XCTAssertNil(model.attachmentURL(for: firstID))
            XCTAssertNil(model.attachmentURL(for: secondID))
            if board.writes == 1 {
                XCTAssertEqual(board.board.itemProviders.count, 3)
                var diagnosticProviderIndex = 1
                for (provider, expected) in zip(board.board.itemProviders.dropFirst(), [Data("old!".utf8), Data("two!".utf8)]) {
                    let type = try XCTUnwrap(provider.registeredTypeIdentifiers.first)
                    let bytes = CopiedFileBytes()
                    let stagedDestinations = board.observedStagingDestinations
                    let diagnosticContext = board.diagnosticContext(for: provider, index: diagnosticProviderIndex,
                                                                    selectedType: type)
                    StagedCopyObserver.log(stagedDestinations, phase: "before-load", context: diagnosticContext)
                    _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                        bytes.read(url, providerError: error, diagnosticContext: diagnosticContext,
                                   stagedDestinations: stagedDestinations)
                    }
                    guard await fixture.ready(bytes.loaded, "actual multi-copy file bytes loaded") else { return }
                    XCTAssertEqual(bytes.data, expected)
                    diagnosticProviderIndex += 1
                }
            }
        } else {
            XCTAssertEqual(copying.result, false)
            XCTAssertEqual(board.writes, 0)
            XCTAssertEqual(board.board.string, "Keep this clipboard until a valid copy finishes")
            XCTAssertNil(coordinator.shareRequest)
        }
        let durable = try await fixture.reopen(replacement ?? fixture.original)
        switch change {
        case .identityThenDeletion, .exportDeletion, .ordinaryDeletion:
            XCTAssertTrue(durable.snips.isEmpty)
            XCTAssertTrue(model.snips.isEmpty)
            XCTAssertNil(model.attachmentURL(for: firstID))
            XCTAssertNil(model.attachmentURL(for: secondID))
            XCTAssertEqual(model.attachmentTransferState(for: firstID), .waiting)
            XCTAssertEqual(model.attachmentTransferState(for: secondID), .waiting)
        case .identity:
            XCTAssertEqual(durable.snips.map(\.content), ["Edited during captured copy"])
            XCTAssertFalse(durable.snips.flatMap(\.attachments).contains { $0.id == firstID })
            XCTAssertTrue(durable.snips.flatMap(\.attachments).contains { $0.id == secondID })
            let changed = try XCTUnwrap(durable.snips.flatMap(\.attachments).first { $0.fileName == "changed.txt" })
            let file = try XCTUnwrap(durable.attachmentURLs[changed.id])
            XCTAssertEqual(try Data(contentsOf: file), Data("changed!".utf8))
        case .source: XCTAssertEqual(durable.snips.map(\.content), ["Replacement source"])
        case .files, .cancel: XCTAssertEqual(durable.snips.map(\.content), ["Original source"])
        }
        XCTAssertTrue(durable.snips.allSatisfy { !$0.isDone })
        XCTAssertNil(model.errorMessage)
    }
}

extension IOSOfflineLocalFeedbackTests {
    func testDeletedCopyCannotAdmitALaterAttachmentAfterItsOwnerDisappears() async throws {
        let fixture = try await StatusGuardFixture.make(twoAttachments: true)
        do {
            try await exerciseDeletionBeforeLaterAdmission(fixture)
            await fixture.cleanUp()
        } catch {
            await fixture.cleanUp()
            throw error
        }
    }

    private func exerciseDeletionBeforeLaterAdmission(_ fixture: StatusGuardFixture) async throws {
        let model = try XCTUnwrap(fixture.model)
        let board = try CapturedCopyBoard(root: fixture.root)
        defer { board.close() }
        let firstID = StatusGuardFixture.attachmentID
        let secondID = StatusGuardFixture.secondAttachmentID
        await fixture.handler.set(mode: true, states: [firstID: .waiting, secondID: .waiting])
        let loading = fixture.start { await model.load(); return true }
        guard await fixture.ready(loading.finished, "late-admission initial attachment knowledge") else { return }
        let snip = try XCTUnwrap(model.snips.first)
        let first = fixture.gate()
        let neverAdmitted = fixture.gate()
        await fixture.handler.enqueuePrepare(fixture.originalPrepared, gate: first)
        await fixture.handler.enqueuePrepare(fixture.root.appendingPathComponent("verified-second.txt"), gate: neverAdmitted)
        let coordinator = IOSCopyShareCoordinator(pasteboard: board)
        let copying = fixture.start { await coordinator.copy(snips: [snip], model: model) }
        guard await fixture.ready(first.entered, "only first attachment was admitted") else { return }
        await fixture.handler.set(mode: true, states: [:])
        let deleting = fixture.start { await model.deleteSnip(id: StatusGuardFixture.snipID) }
        guard await fixture.completed(deleting, "Owner deletion committed before second admission") else { return }
        XCTAssertEqual(deleting.result, true)
        first.release()
        guard await fixture.completed(copying, "Copy must reject an attachment missing at admission") else { return }
        XCTAssertEqual(copying.result, false)
        XCTAssertEqual(board.writes, 0)
        XCTAssertFalse(neverAdmitted.entered.isSet)
        let calls = await fixture.handler.snapshotCounts()
        XCTAssertEqual(calls.entries[.prepare], 1)
        XCTAssertNil(model.attachmentURL(for: firstID))
        XCTAssertNil(model.attachmentURL(for: secondID))
        let durable = try await fixture.reopen(fixture.original)
        XCTAssertTrue(durable.snips.isEmpty)
    }
}
