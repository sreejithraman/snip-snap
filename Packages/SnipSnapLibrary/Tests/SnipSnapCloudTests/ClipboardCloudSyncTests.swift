import CloudKit
import Foundation
import Observation
import Synchronization
import Testing
import SnipSnapCore
import SnipSnapPersistence
@testable import SnipSnapCloud

private actor ClipboardTestCloud: ClipboardCloudTransport {
    var snapshot = ClipboardCloudSnapshot()
    var serial = 0
    var unavailable = false
    var conflictOnce = false
    var rateLimitedFetches = 0
    var rateLimitedDeletes = 0
    var rateLimitedSaves = 0
    var fetchObserver: (@Sendable () -> Void)?
    var fetchRequests = 0
    var pauseSave = false
    var paused: CheckedContinuation<Void, Never>?
    var pausedSaveError: (any Error)?
    func pauseNextSave() { pauseSave = true }
    /// Pauses the next save, which throws `error` once resumed.
    func pauseNextSave(thenThrow error: any Error) { pauseSave = true; pausedSaveError = error }
    func hasPaused() -> Bool { paused != nil }
    func resumeSave() { paused?.resume(); paused = nil }
    /// Waits for a save to pause. On timeout it disarms the pause, so no later save hangs.
    func savePaused(within timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while paused == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if paused == nil { pauseSave = false; pausedSaveError = nil }
        return paused != nil
    }
    func setUnavailable(_ value: Bool) { unavailable = value }
    func setConflict() { conflictOnce = true }
    func rateLimitFetches(_ count: Int) { rateLimitedFetches = count }
    func rateLimitDeletes(_ count: Int) { rateLimitedDeletes = count }
    func rateLimitSaves(_ count: Int) { rateLimitedSaves = count }
    func observeFetches(_ observer: @escaping @Sendable () -> Void) { fetchObserver = observer }
    func fetchCount() -> Int { fetchRequests }
    func fetch() throws -> ClipboardCloudSnapshot {
        fetchRequests += 1
        fetchObserver?()
        if rateLimitedFetches > 0 {
            rateLimitedFetches -= 1
            throw Self.rateLimited()
        }
        if unavailable { throw ClipboardCloudError.unavailable }
        return snapshot
    }
    func save(_ incoming: ClipboardCloudSnapshot, cancellation: ClipboardCloudCancellation) async throws {
        if pauseSave {
            pauseSave = false
            await withCheckedContinuation { paused = $0 }
            if let error = pausedSaveError { pausedSaveError = nil; throw error }
        }
        try cancellation.check()
        if rateLimitedSaves > 0 {
            rateLimitedSaves -= 1
            throw Self.rateLimited()
        }
        if unavailable { throw ClipboardCloudError.unavailable }
        if conflictOnce { conflictOnce = false; throw ClipboardCloudError.conflict }
        guard incoming.version == snapshot.version else { throw ClipboardCloudError.conflict }
        serial += 1; snapshot = incoming; snapshot.version = Data(String(serial).utf8)
    }
    func deleteAll() throws {
        if rateLimitedDeletes > 0 {
            rateLimitedDeletes -= 1
            throw Self.rateLimited()
        }
        snapshot = ClipboardCloudSnapshot()
    }
    private static func rateLimited() -> CKError {
        CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.requestRateLimited.rawValue,
            userInfo: [CKErrorRetryAfterKey: 10]
        ))
    }
}

/// The device's current iCloud account, which a test can switch, and how often the service checked
/// it. After `holdNextCheck(for:)`, the next check waits for `release(answering:)`; later ones answer
/// at once. A hold that isn't released in time ends by itself, so a regression fails instead of hanging.
private final class ClipboardTestAccount: ICloudAccountStateSource {
    private struct Account {
        var state: ICloudAccountState
        var checks = 0
        var holdsNextCheck = false
        var heldCheck: CheckedContinuation<ICloudAccountState, Never>?
        var heldCheckWaiters: [CheckedContinuation<Void, Never>] = []
        var holdDeadline: Task<Void, Never>?
        var holdTimedOut = false
        var isHolding: Bool { holdsNextCheck || heldCheck != nil }
    }
    private let account: Mutex<Account>

    init(_ state: ICloudAccountState) {
        account = Mutex(Account(state: state))
    }

    var checks: Int { account.withLock { $0.checks } }

    func switchTo(_ state: ICloudAccountState) {
        account.withLock { $0.state = state }
    }

    /// Whether a hold ended at its deadline instead of by `release(answering:)`.
    var holdTimedOut: Bool { account.withLock { $0.holdTimedOut } }

    /// Holds the next check. Without `release(answering:)` within `timeout`, the hold ends: a held
    /// check answers with the current state, and `checkHeld()` returns.
    func holdNextCheck(for timeout: Duration = .seconds(5)) {
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.endHold(answering: nil)
        }
        account.withLock { account in
            account.holdsNextCheck = true
            account.holdDeadline = deadline
        }
    }

    /// Returns once the held check is waiting for its answer, or the hold has ended.
    func checkHeld() async {
        await withCheckedContinuation { waiter in
            let waits = account.withLock { account in
                guard account.holdsNextCheck else { return false }
                account.heldCheckWaiters.append(waiter)
                return true
            }
            if !waits { waiter.resume() }
        }
    }

    /// Switches to `state` and answers the held check with it.
    func release(answering state: ICloudAccountState) {
        endHold(answering: state)
    }

    /// Ends the hold. With no `state`, the deadline passed, and a held check gets the current state.
    private func endHold(answering state: ICloudAccountState?) {
        let ended: (answer: ICloudAccountState, check: CheckedContinuation<ICloudAccountState, Never>?,
                    waiters: [CheckedContinuation<Void, Never>], deadline: Task<Void, Never>?) =
            account.withLock { account in
                if let state {
                    account.state = state
                } else if account.isHolding {
                    account.holdTimedOut = true
                }
                defer {
                    account.holdsNextCheck = false
                    account.heldCheck = nil
                    account.heldCheckWaiters = []
                    account.holdDeadline = nil
                }
                return (account.state, account.heldCheck, account.heldCheckWaiters, account.holdDeadline)
            }
        if state != nil { ended.deadline?.cancel() }
        ended.check?.resume(returning: ended.answer)
        for waiter in ended.waiters { waiter.resume() }
    }

    func currentAccountState() async -> ICloudAccountState {
        await withCheckedContinuation { check in
            let outcome: (answer: ICloudAccountState?, waiters: [CheckedContinuation<Void, Never>]) =
                account.withLock { account in
                    account.checks += 1
                    guard account.holdsNextCheck else { return (account.state, []) }
                    account.holdsNextCheck = false
                    account.heldCheck = check
                    defer { account.heldCheckWaiters = [] }
                    return (nil, account.heldCheckWaiters)
                }
            if let answer = outcome.answer { check.resume(returning: answer) }
            for waiter in outcome.waiters { waiter.resume() }
        }
    }
}

@MainActor private struct ClipboardClient {
    let root: URL
    let store: ClipboardHistoryStore
    let files: ClipboardFileStore
    let sync: ClipboardCloudSyncService
    init(_ cloud: ClipboardTestCloud, retry: CloudKitOperationRetry = CloudKitOperationRetry(),
         resetStep: @escaping @MainActor (ClipboardBindingResetStep) async throws -> Void = { _ in },
         accountState: (any ICloudAccountStateSource)? = nil) {
        self.init(retry: retry, resetStep: resetStep, accountState: accountState, makeTransport: { _ in cloud })
    }
    init(retry: CloudKitOperationRetry = CloudKitOperationRetry(),
         resetStep: @escaping @MainActor (ClipboardBindingResetStep) async throws -> Void = { _ in },
         accountState: (any ICloudAccountStateSource)? = nil,
         makeTransport: @escaping @Sendable (String) -> any ClipboardCloudTransport) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        files = ClipboardFileStore(rootURL: root.appendingPathComponent("ClipboardFiles"))
        store = ClipboardHistoryStore(url: root.appendingPathComponent("clipboard.json"), fileStore: files)
        sync = ClipboardCloudSyncService(store: store, syncRootURL: root, makeTransport: makeTransport,
                                         accountState: accountState, retry: retry, resetStep: resetStep)
    }
    var bindingURL: URL { root.appendingPathComponent("clipboard-account-binding.json") }
    /// A new service on the same root and store, as after the old one is discarded.
    init(reopening previous: ClipboardClient, _ cloud: ClipboardTestCloud) {
        self.init(reopening: previous, makeTransport: { _ in cloud })
    }
    init(reopening previous: ClipboardClient,
         makeTransport: @escaping @Sendable (String) -> any ClipboardCloudTransport) {
        root = previous.root
        files = previous.files
        store = previous.store
        sync = ClipboardCloudSyncService(store: store, syncRootURL: root, makeTransport: makeTransport)
    }
    @discardableResult func run(enabled: Bool = true, scope: String = "account-generation-A") async throws -> ClipboardHistoryState {
        try await run(scope: scope, isEnabled: { enabled })
    }
    @discardableResult func run(scope: String = "account-generation-A", isEnabled: @escaping @MainActor @Sendable () -> Bool) async throws -> ClipboardHistoryState {
        try await sync.synchronize(generation: scope, isEnabled: isEnabled)
    }
    /// Runs on the caller's actor up to the sync's first suspension, so a sync blocked on a
    /// stopped run is already waiting when this returns.
    func startRun(isEnabled: @escaping @MainActor @Sendable () -> Bool = { true }) -> Task<ClipboardHistoryState, any Error> {
        Task.immediate { try await self.run(isEnabled: isEnabled) }
    }
}

@MainActor @Observable private final class ClipboardOptIn {
    var isOn = true
}

/// An opt-in the service's Observations watch can't see change.
@MainActor private final class ClipboardUnobservedOptIn {
    var isOn = true
}

/// Checks `condition` until it holds or `timeout` passes, and returns whether it holds.
@MainActor private func eventually(within timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Ends the test, cancelling `run`, if its save doesn't pause.
private func requireSavePaused<Success: Sendable>(
    _ cloud: ClipboardTestCloud,
    during run: Task<Success, any Error>
) async throws {
    let paused = await cloud.savePaused()
    if !paused { run.cancel() }
    try #require(paused, "The save never paused")
}

/// The saved-snips namespace key the apps pass as the clipboard generation.
private func namespaceKey(cloudScope: String = "private", account: String, generation: UUID) -> String {
    let value = generation.uuidString.lowercased()
    return ICloudSyncNamespaceBinding(
        scope: cloudScope,
        accountLineage: account,
        generation: generation,
        zones: [
            ICloudSyncZoneBinding(name: "snips-\(value)", ownerName: CKCurrentUserDefaultName),
            ICloudSyncZoneBinding(name: "payloads-\(value)", ownerName: CKCurrentUserDefaultName),
        ]
    ).namespaceKey.rawValue
}

/// The entry IDs in each clipboard history set aside under `root`.
private func setAsideEntryIDs(in root: URL) async throws -> [[UUID]] {
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("clipboard-quarantine-") }
    var histories: [[UUID]] = []
    for file in files {
        histories.append(try await ClipboardHistoryStore(url: file).load().entries.map(\.id))
    }
    return histories
}

/// Where a crash interrupts a set-aside: after copying the history, or after emptying the store.
enum ClipboardSetAsideCrash: CaseIterable, Sendable {
    case afterCopy, afterEmptySave
}

@Suite @MainActor struct ClipboardCloudSyncTests {
    @Test func payloadReferencesUseRandomNamesAndDetectManifestConflicts() throws {
        let data = Data("private clipboard content".utf8)
        let first = ClipboardCloudPayloadReference(data: data)
        let second = ClipboardCloudPayloadReference(data: data)
        #expect(UUID(uuidString: first.recordName) != nil)
        #expect(first.recordName != second.recordName)
        #expect(first.digest == second.digest)
        let id = CKRecord.ID(recordName: "manifest")
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.serverRecordChanged)]])
        #expect(CloudKitClipboardTransport.isConflict(partial, recordID: id))
        #expect(!CloudKitClipboardTransport.isConflict(CKError(.networkFailure), recordID: id))
    }

    @Test func deleteSyncedHistoryKeepsRecoveryFileBytes() async throws {
        let client = ClipboardClient(ClipboardTestCloud())
        defer { try? FileManager.default.removeItem(at: client.root) }
        try FileManager.default.createDirectory(at: client.root, withIntermediateDirectories: true)
        let source = client.root.appendingPathComponent("important.txt")
        let data = Data("Keep recovery bytes".utf8)
        try data.write(to: source)
        let clip = ClipboardEntry(items: [.init(representations: [.init(type: "public.file-url", data: Data(source.absoluteString.utf8))])])
        try await client.store.insert(clip)
        try await client.store.setPinned(true, id: clip.id)
        let shared = try await client.run()
        let owned = try #require(shared.entries.first?.ownedFiles.first)
        try await client.sync.deleteSyncedHistory(generation: "account-generation-A")
        #expect(try await client.store.load().entries.isEmpty)
        #expect(try Data(contentsOf: client.files.url(for: owned)) == data)
        let backups = try FileManager.default.contentsOfDirectory(at: client.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("clipboard-quarantine-") }
        #expect(backups.count == 1)
    }

    @Test func sharedFileSizesSurviveSyncAndUnpinForRetention() async throws {
        let cloud = ClipboardTestCloud(); let a = ClipboardClient(cloud); let b = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        try FileManager.default.createDirectory(at: a.root, withIntermediateDirectories: true)
        let source = a.root.appendingPathComponent("file.txt")
        let data = Data(repeating: 1, count: 4096)
        try data.write(to: source)
        let clip = ClipboardEntry(items: [.init(representations: [.init(type: "public.file-url", data: Data(source.absoluteString.utf8))])])
        try await a.store.insert(clip); try await a.store.setPinned(true, id: clip.id); try await a.run()
        try await b.run(); try await b.store.setPinned(false, id: clip.id)
        let state = try await b.run()
        let unpinned = try #require(state.entries.first)
        #expect(unpinned.ownedFiles.first?.byteCount == data.count)
        #expect(unpinned.retentionByteCount == unpinned.byteCount + data.count)
        #expect(ClipboardHistoryState.trimmed([unpinned], maximumHistoryBytes: 4096).isEmpty)
    }

    private func entry(_ text: String, pinned: Bool = false) -> ClipboardEntry {
        ClipboardEntry(items: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))])],
                       pinnedAt: pinned ? Date() : nil)
    }
    @Test func optInMergeDeduplicateAndClearAcrossClients() async throws {
        let cloud = ClipboardTestCloud(); let a = ClipboardClient(cloud); let b = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        let pin = entry("keep", pinned: true)
        try await a.store.insert(pin); try await a.store.insert(entry("same"))
        try await b.store.insert(entry("same")); try await b.store.insert(entry("second"))
        try await a.run(enabled: false)
        #expect(try await cloud.fetch().entries.isEmpty)
        try await a.run(); try await b.run()
        #expect(try await a.run().entries.count == 3)
        try await b.store.clearUnpinned(); try await b.run()
        #expect(try await a.run().entries.map(\.id) == [pin.id])
        try await a.store.delete(id: pin.id); try await a.run()
        #expect(try await b.run().entries.isEmpty)
    }
    @Test func offlineDeleteWinsAndConflictRetries() async throws {
        let cloud = ClipboardTestCloud(); let a = ClipboardClient(cloud); let b = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        let clip = entry("offline")
        try await a.store.insert(clip); try await a.run(); try await b.run()
        await cloud.setUnavailable(true)
        try await a.store.delete(id: clip.id)
        await #expect(throws: ClipboardCloudError.unavailable) { try await a.run() }
        #expect(try await a.store.load().entries.isEmpty)
        try await b.store.setPinned(true, id: clip.id)
        await cloud.setUnavailable(false); await cloud.setConflict()
        try await a.run(); #expect(try await b.run().entries.isEmpty)
    }
    @Test func tryAgainHonorsTheServerDeadlineAfterClipboardSyncFails() async throws {
        let clock = ClipboardRetryClock()
        let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { clock.advance($0) })
        let cloud = ClipboardTestCloud()
        let requestTimes = Mutex<[Duration]>([])
        await cloud.observeFetches { requestTimes.withLock { $0.append(clock.elapsed) } }
        await cloud.rateLimitFetches(3)
        let client = ClipboardClient(cloud, retry: retry)
        defer { try? FileManager.default.removeItem(at: client.root) }

        await #expect(throws: CKError.self) { try await client.run() }
        try await client.run()

        #expect(requestTimes.withLock { $0 } == [.zero, .seconds(10), .seconds(20), .seconds(30)])
    }
    @Test func stopCancelsAClipboardRetryWaitBeforeAnotherRequest() async throws {
        let sleep = ClipboardRetrySleepGate()
        let retry = CloudKitOperationRetry(sleep: { _ in try await sleep.wait() })
        let cloud = ClipboardTestCloud()
        await cloud.rateLimitFetches(1)
        let client = ClipboardClient(cloud, retry: retry)
        defer { try? FileManager.default.removeItem(at: client.root) }

        let running = Task { try await client.run() }
        let deadline = ContinuousClock.now + .seconds(10)
        while !sleep.isWaiting && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sleep.isWaiting)
        client.sync.stop()

        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await cloud.fetchCount() == 1)
    }
    @Test func retryRechecksAnUnobservedOptInBeforeAnotherRequest() async throws {
        let clock = ClipboardRetryClock()
        let sleep = ClipboardRetrySleepGate()
        let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { duration in
            try await sleep.wait()
            clock.advance(duration)
        })
        let cloud = ClipboardTestCloud()
        await cloud.rateLimitFetches(1)
        let client = ClipboardClient(cloud, retry: retry)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("stays local"))
        let optIn = ClipboardUnobservedOptIn()
        let running = client.startRun(isEnabled: { optIn.isOn })

        let waiting = await eventually { sleep.isWaiting }
        if !waiting { running.cancel() }
        try #require(waiting, "The fetch retry never waited")
        optIn.isOn = false
        sleep.release()

        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await cloud.fetchCount() == 1)
        #expect(try await cloud.fetch().entries.isEmpty)
    }
    @Test func retrySleepRejectsAnAlreadyCancelledTask() async throws {
        let sleep = ClipboardRetrySleepGate()
        let completed = Mutex(false)
        let running = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            defer { completed.withLock { $0 = true } }
            try await sleep.wait()
        }
        defer {
            running.cancel()
            sleep.cancelWaiter()
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !completed.withLock({ $0 }) && !sleep.isWaiting && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let finished = completed.withLock { $0 }
        let waiting = sleep.isWaiting
        #expect(finished)
        guard finished || waiting else { return }
        sleep.cancelWaiter()
        await #expect(throws: CancellationError.self) { try await running.value }
    }
    @Test func accountChangeRequiresQuarantineAndDoesNotUploadOldData() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("account A")); try await client.run()
        await #expect(throws: ClipboardCloudError.accountChanged) { try await client.run(scope: "account B") }
        try await client.sync.resetAccountBinding()
        #expect(try await client.store.load().entries.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: client.root.path).contains { $0.hasPrefix("clipboard-quarantine-") })
    }
    @Test func newSyncGenerationInTheSameAccountIsNotAnAccountChange() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("first generation"))
        try await client.run(scope: namespaceKey(account: "account-A", generation: UUID()))
        await #expect(throws: ClipboardCloudError.syncGenerationChanged) {
            try await client.run(scope: namespaceKey(account: "account-A", generation: UUID()))
        }
    }
    @Test func relaunchedServiceTreatsANewSyncGenerationAsTheSameAccount() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("first generation"))
        try await client.run(scope: namespaceKey(account: "account-A", generation: UUID()))
        let relaunched = ClipboardClient(reopening: client, cloud)
        await #expect(throws: ClipboardCloudError.syncGenerationChanged) {
            try await relaunched.run(scope: namespaceKey(account: "account-A", generation: UUID()))
        }
    }
    @Test func setAsideHistoryNeverUploadsIntoTheNewSyncGeneration() async throws {
        let first = namespaceKey(account: "account-A", generation: UUID())
        let second = namespaceKey(account: "account-A", generation: UUID())
        let firstCloud = ClipboardTestCloud(); let secondCloud = ClipboardTestCloud()
        let client = ClipboardClient(makeTransport: { $0 == first ? firstCloud : secondCloud })
        defer { try? FileManager.default.removeItem(at: client.root) }
        let bindingURL = client.root.appendingPathComponent("clipboard-account-binding.json")
        let older = entry("first generation")
        try await client.store.insert(older); try await client.run(scope: first)

        await #expect(throws: ClipboardCloudError.syncGenerationChanged) { try await client.run(scope: second) }
        #expect(try await secondCloud.fetch().entries.isEmpty)
        #expect(try await client.store.load().entries.map(\.id) == [older.id])
        #expect(try Data(contentsOf: bindingURL) == JSONEncoder().encode(first))

        try await client.sync.resetAccountBinding()
        #expect(try await client.store.load().entries.isEmpty)
        #expect(try await setAsideEntryIDs(in: client.root) == [[older.id]])
        let newer = entry("second generation")
        try await client.store.insert(newer); try await client.run(scope: second)
        #expect(Set(try await secondCloud.fetch().entries.keys) == [newer.id])
        #expect(try Data(contentsOf: bindingURL) == JSONEncoder().encode(second))
    }
    @Test func relaunchedServiceFollowsANewSyncGenerationAfterSettingHistoryAside() async throws {
        let first = namespaceKey(account: "account-A", generation: UUID())
        let second = namespaceKey(account: "account-A", generation: UUID())
        let firstCloud = ClipboardTestCloud(); let secondCloud = ClipboardTestCloud()
        let transport: @Sendable (String) -> any ClipboardCloudTransport = { $0 == first ? firstCloud : secondCloud }
        let client = ClipboardClient(makeTransport: transport)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let older = entry("first generation")
        try await client.store.insert(older); try await client.run(scope: first)

        let relaunched = ClipboardClient(reopening: client, makeTransport: transport)
        await #expect(throws: ClipboardCloudError.syncGenerationChanged) { try await relaunched.run(scope: second) }
        try await relaunched.sync.resetAccountBinding()
        let newer = entry("second generation")
        try await relaunched.store.insert(newer); try await relaunched.run(scope: second)
        #expect(try await setAsideEntryIDs(in: client.root) == [[older.id]])
        #expect(Set(try await secondCloud.fetch().entries.keys) == [newer.id])
    }
    @Test(arguments: ClipboardSetAsideCrash.allCases)
    func relaunchAfterAnInterruptedSetAsideSetsHistoryAsideAgainAndFollows(_ crash: ClipboardSetAsideCrash) async throws {
        let first = namespaceKey(account: "account-A", generation: UUID())
        let second = namespaceKey(account: "account-A", generation: UUID())
        let firstCloud = ClipboardTestCloud(); let secondCloud = ClipboardTestCloud()
        let transport: @Sendable (String) -> any ClipboardCloudTransport = { $0 == first ? firstCloud : secondCloud }
        let client = ClipboardClient(makeTransport: transport)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let bindingURL = client.root.appendingPathComponent("clipboard-account-binding.json")
        let older = entry("first generation")
        try await client.store.insert(older); try await client.run(scope: first)

        // What the interrupted set-aside left on disk; the first binding is still there.
        let copy = client.root.appendingPathComponent("clipboard-quarantine-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: client.store.url, to: copy)
        if crash == .afterEmptySave { try await client.store.save(ClipboardHistoryState()) }

        let relaunched = ClipboardClient(reopening: client, makeTransport: transport)
        await #expect(throws: ClipboardCloudError.syncGenerationChanged) { try await relaunched.run(scope: second) }
        try await relaunched.sync.resetAccountBinding()
        let newer = entry("second generation")
        try await relaunched.store.insert(newer); try await relaunched.run(scope: second)

        #expect(try Data(contentsOf: bindingURL) == JSONEncoder().encode(second))
        let remote = try await secondCloud.fetch()
        #expect(Set(remote.entries.keys) == [newer.id])
        #expect(remote.tombstones[older.id] == nil)
        let setAside = try await setAsideEntryIDs(in: client.root)
        #expect(setAside.allSatisfy { Set($0).isSubset(of: [older.id]) })
        #expect(setAside.contains([older.id]))
        let active = try await relaunched.store.load()
        #expect(!active.entries.contains { $0.id == older.id })
    }
    @Test func otherAccountOrCloudScopeIsAnAccountChangeAndKeepsTheBindingFile() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let generation = UUID()
        let bound = namespaceKey(account: "account-A", generation: generation)
        try await client.store.insert(entry("account A")); try await client.run(scope: bound)
        await #expect(throws: ClipboardCloudError.accountChanged) {
            try await client.run(scope: namespaceKey(account: "account-B", generation: generation))
        }
        await #expect(throws: ClipboardCloudError.accountChanged) {
            try await client.run(scope: namespaceKey(cloudScope: "shared", account: "account-A", generation: generation))
        }
        let stored = try Data(contentsOf: client.root.appendingPathComponent("clipboard-account-binding.json"))
        #expect(try stored == JSONEncoder().encode(bound))
    }
    @Test func unboundHistoryNeverUploadsWhileTheDeviceIsOnAnotherAccount() async throws {
        let cloud = ClipboardTestCloud()
        let client = ClipboardClient(cloud, accountState: ClipboardTestAccount(.available(accountLineage: "account-B")))
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("copied under account A"))

        await #expect(throws: ClipboardCloudError.accountChanged) {
            try await client.run(scope: namespaceKey(account: "account-A", generation: UUID()))
        }
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: client.bindingURL.path))
    }
    @Test func boundHistoryNeverUploadsWhileTheDeviceIsOnAnotherAccount() async throws {
        let cloud = ClipboardTestCloud()
        let account = ClipboardTestAccount(.available(accountLineage: "account-A"))
        let client = ClipboardClient(cloud, accountState: account)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let accountA = namespaceKey(account: "account-A", generation: UUID())
        let synced = entry("synced under account A")
        try await client.store.insert(synced); try await client.run(scope: accountA)

        account.switchTo(.available(accountLineage: "account-B"))
        try await client.store.insert(entry("copied after the device switched accounts"))
        await #expect(throws: ClipboardCloudError.accountChanged) { try await client.run(scope: accountA) }
        #expect(Set(try await cloud.fetch().entries.keys) == [synced.id])
        #expect(try Data(contentsOf: client.bindingURL) == JSONEncoder().encode(accountA))
    }
    @Test(arguments: [
        (ICloudAccountState.temporarilyUnavailable, ICloudAccountGateError.temporarilyUnavailable),
        (.noAccount, .noAccount), (.restricted, .restricted), (.couldNotDetermine, .couldNotDetermine),
    ])
    func unavailableAccountNeverBindsOrUploads(_ state: ICloudAccountState, _ error: ICloudAccountGateError) async throws {
        let cloud = ClipboardTestCloud()
        let client = ClipboardClient(cloud, accountState: ClipboardTestAccount(state))
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("copied under account A"))

        await #expect(throws: error) {
            try await client.run(scope: namespaceKey(account: "account-A", generation: UUID()))
        }
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: client.bindingURL.path))
    }
    @Test func accountSwitchBeforeTheSaveUploadsNothing() async throws {
        let cloud = ClipboardTestCloud()
        let account = ClipboardTestAccount(.available(accountLineage: "account-A"))
        // The device signs in to account B after the run's fetch and before its save.
        await cloud.observeFetches { account.switchTo(.available(accountLineage: "account-B")) }
        let client = ClipboardClient(cloud, accountState: account)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("copied under account A"))

        await #expect(throws: ClipboardCloudError.accountChanged) {
            try await client.run(scope: namespaceKey(account: "account-A", generation: UUID()))
        }
        #expect(await cloud.serial == 0)
        #expect(try await cloud.fetch().entries.isEmpty)
    }
    @Test func accountChecksPerRunAreBounded() async throws {
        let cloud = ClipboardTestCloud()
        let account = ClipboardTestAccount(.available(accountLineage: "account-A"))
        let client = ClipboardClient(cloud, accountState: account)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let accountA = namespaceKey(account: "account-A", generation: UUID())
        // One check before binding, then one before each save attempt.
        func checks(during run: () async throws -> Void) async rethrows -> Int {
            let before = account.checks
            try await run()
            return account.checks - before
        }

        try await client.store.insert(entry("first"))
        let oneSave = try await checks { try await client.run(scope: accountA) }
        let nothingToUpload = try await checks { try await client.run(scope: accountA) }
        try await client.store.insert(entry("second")); await cloud.setConflict()
        let conflictThenSave = try await checks { try await client.run(scope: accountA) }

        #expect(oneSave == 2)
        #expect(nothingToUpload == 1)
        #expect(conflictThenSave == 3)
        #expect(await cloud.serial == 2)
    }
    @Test func deleteSyncedHistoryUnderAnotherAccountDeletesAndBindsNothing() async throws {
        let cloud = ClipboardTestCloud()
        let account = ClipboardTestAccount(.available(accountLineage: "account-A"))
        let bound = ClipboardClient(cloud, accountState: account)
        let unbound = ClipboardClient(cloud, accountState: ClipboardTestAccount(.available(accountLineage: "account-B")))
        defer { try? FileManager.default.removeItem(at: bound.root); try? FileManager.default.removeItem(at: unbound.root) }
        let accountA = namespaceKey(account: "account-A", generation: UUID())
        let synced = entry("synced under account A")
        try await bound.store.insert(synced); try await bound.run(scope: accountA)
        account.switchTo(.available(accountLineage: "account-B"))

        await #expect(throws: ClipboardCloudError.accountChanged) { try await bound.sync.deleteSyncedHistory(generation: accountA) }
        await #expect(throws: ClipboardCloudError.accountChanged) { try await unbound.sync.deleteSyncedHistory(generation: accountA) }
        #expect(Set(try await cloud.fetch().entries.keys) == [synced.id])
        #expect(try await bound.store.load().entries.map(\.id) == [synced.id])
        #expect(try await setAsideEntryIDs(in: bound.root).isEmpty)
        #expect(try Data(contentsOf: bound.bindingURL) == JSONEncoder().encode(accountA))
        #expect(!FileManager.default.fileExists(atPath: unbound.bindingURL.path))
    }
    @Test func checkedAccountRefusesAGenerationThatIsNotANamespaceKey() async throws {
        let cloud = ClipboardTestCloud()
        let account = ClipboardTestAccount(.available(accountLineage: "account-A"))
        let client = ClipboardClient(cloud, accountState: account)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("copied under account A"))

        await #expect(throws: ClipboardCloudError.unavailable) { try await client.run(scope: "account-generation-A") }
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: client.bindingURL.path))
        #expect(account.checks == 0)
    }
    @Test func stopDuringTheDeleteAccountCheckCancelsTheDelete() async throws {
        let cloud = ClipboardTestCloud()
        let account = ClipboardTestAccount(.available(accountLineage: "account-A"))
        let client = ClipboardClient(cloud, accountState: account)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let accountA = namespaceKey(account: "account-A", generation: UUID())
        let bindingA = try JSONEncoder().encode(accountA)
        let synced = entry("synced under account A")
        try await client.store.insert(synced); try await client.run(scope: accountA)

        account.holdNextCheck()
        let deleting = Task { try await client.sync.deleteSyncedHistory(generation: accountA) }
        await account.checkHeld()
        client.sync.stop()
        account.release(answering: .available(accountLineage: "account-A"))
        #expect(!account.holdTimedOut)

        await #expect(throws: CancellationError.self) { try await deleting.value }
        #expect(Set(try await cloud.fetch().entries.keys) == [synced.id])
        #expect((try? Data(contentsOf: client.bindingURL)) == bindingA)
        #expect(try await setAsideEntryIDs(in: client.root).isEmpty)
    }
    @Test func stopDuringTheDeleteAccountCheckBindsNothingForUnboundHistory() async throws {
        let cloud = ClipboardTestCloud()
        let account = ClipboardTestAccount(.available(accountLineage: "account-A"))
        let client = ClipboardClient(cloud, accountState: account)
        let otherDevice = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root); try? FileManager.default.removeItem(at: otherDevice.root) }
        let accountA = namespaceKey(account: "account-A", generation: UUID())
        let shared = entry("synced by another device")
        try await otherDevice.store.insert(shared); try await otherDevice.run(scope: accountA)
        let local = entry("never synced")
        try await client.store.insert(local)

        account.holdNextCheck()
        let deleting = Task { try await client.sync.deleteSyncedHistory(generation: accountA) }
        await account.checkHeld()
        client.sync.stop()
        account.release(answering: .available(accountLineage: "account-A"))
        #expect(!account.holdTimedOut)

        await #expect(throws: CancellationError.self) { try await deleting.value }
        #expect(!FileManager.default.fileExists(atPath: client.bindingURL.path))
        #expect(Set(try await cloud.fetch().entries.keys) == [shared.id])
        #expect(try await client.store.load().entries.map(\.id) == [local.id])
    }
    @Test func stopWhileADeleteWaitsForAStoppingRunCancelsTheDelete() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let bindingA = try JSONEncoder().encode("account-generation-A")
        let synced = entry("synced")
        try await client.store.insert(synced); try await client.run()
        try await client.store.insert(entry("copied later"))
        await cloud.pauseNextSave()
        let running = Task { try await client.run() }
        try await requireSavePaused(cloud, during: running)

        // The delete stops the run and waits in `beginUnbinding` for it to unwind.
        let deleting = Task.immediate { try await client.sync.deleteSyncedHistory(generation: "account-generation-A") }
        client.sync.stop()
        await cloud.resumeSave()

        await #expect(throws: CancellationError.self) { try await deleting.value }
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(Set(try await cloud.fetch().entries.keys) == [synced.id])
        #expect((try? Data(contentsOf: client.bindingURL)) == bindingA)
        #expect(try await setAsideEntryIDs(in: client.root).isEmpty)
    }
    @Test func stopDuringThePreBindAccountCheckBindsNothing() async throws {
        let cloud = ClipboardTestCloud()
        let account = ClipboardTestAccount(.available(accountLineage: "account-A"))
        let client = ClipboardClient(cloud, accountState: account)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("copied under account A"))

        account.holdNextCheck()
        let running = Task { try await client.run(scope: namespaceKey(account: "account-A", generation: UUID())) }
        await account.checkHeld()
        client.sync.stop()
        account.release(answering: .available(accountLineage: "account-A"))
        #expect(!account.holdTimedOut)

        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(!FileManager.default.fileExists(atPath: client.bindingURL.path))
        #expect(await cloud.fetchCount() == 0)
        #expect(await cloud.serial == 0)
    }
    @Test func accountResetDuringThePreBindAccountCheckBindsNothing() async throws {
        let cloud = ClipboardTestCloud()
        let account = ClipboardTestAccount(.available(accountLineage: "account-A"))
        let client = ClipboardClient(cloud, accountState: account)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("never synced"))

        account.holdNextCheck()
        let running = Task { try await client.run(scope: namespaceKey(account: "account-A", generation: UUID())) }
        await account.checkHeld()
        try await client.sync.resetAccountBinding(includingUnboundHistory: true)
        let leftByReset = try? Data(contentsOf: client.bindingURL)
        account.release(answering: .available(accountLineage: "account-A"))
        #expect(!account.holdTimedOut)

        await #expect(throws: CancellationError.self) { try await running.value }
        #expect((try? Data(contentsOf: client.bindingURL)) == leftByReset)
        #expect(await cloud.fetchCount() == 0)
        #expect(await cloud.serial == 0)
    }
    @Test func secondSyncDuringThePreBindAccountCheckIsBusy() async throws {
        let cloud = ClipboardTestCloud()
        let account = ClipboardTestAccount(.available(accountLineage: "account-A"))
        let client = ClipboardClient(cloud, accountState: account)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let accountA = namespaceKey(account: "account-A", generation: UUID())
        let copy = entry("copied under account A")
        try await client.store.insert(copy)

        account.holdNextCheck()
        let first = Task { try await client.run(scope: accountA) }
        await account.checkHeld()
        await #expect(throws: ClipboardCloudError.busy) { try await client.run(scope: accountA) }
        account.release(answering: .available(accountLineage: "account-A"))
        #expect(!account.holdTimedOut)

        #expect(try await first.value.entries.map(\.id) == [copy.id])
        #expect(Set(try await cloud.fetch().entries.keys) == [copy.id])
    }
    @Test func failedAccountCheckLeavesTheServiceReadyForTheNextRun() async throws {
        let cloud = ClipboardTestCloud()
        let account = ClipboardTestAccount(.available(accountLineage: "account-B"))
        let client = ClipboardClient(cloud, accountState: account)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let accountA = namespaceKey(account: "account-A", generation: UUID())
        let copy = entry("copied under account A")
        try await client.store.insert(copy)

        await #expect(throws: ClipboardCloudError.accountChanged) { try await client.run(scope: accountA) }
        account.switchTo(.available(accountLineage: "account-A"))
        try await client.run(scope: accountA)

        #expect(Set(try await cloud.fetch().entries.keys) == [copy.id])
    }
    @Test func everySaveAttemptChecksTheAccount() async throws {
        let clock = ClipboardRetryClock()
        let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { clock.advance($0) })
        let cloud = ClipboardTestCloud()
        await cloud.rateLimitSaves(1)
        let account = ClipboardTestAccount(.available(accountLineage: "account-A"))
        let client = ClipboardClient(cloud, retry: retry, accountState: account)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("copied under account A"))

        try await client.run(scope: namespaceKey(account: "account-A", generation: UUID()))

        // One check before binding, then one before each of the two save attempts.
        #expect(account.checks == 3)
        #expect(await cloud.serial == 1)
    }
    @Test func deleteRechecksTheAccountBeforeEachAttempt() async throws {
        let clock = ClipboardRetryClock()
        let account = ClipboardTestAccount(.available(accountLineage: "account-A"))
        // The device signs in to account B while the delete waits out its backoff.
        let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { duration in
            account.switchTo(.available(accountLineage: "account-B"))
            clock.advance(duration)
        })
        let cloud = ClipboardTestCloud()
        let client = ClipboardClient(cloud, retry: retry, accountState: account)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let accountA = namespaceKey(account: "account-A", generation: UUID())
        let bindingA = try JSONEncoder().encode(accountA)
        let synced = entry("synced under account A")
        try await client.store.insert(synced); try await client.run(scope: accountA)
        await cloud.rateLimitDeletes(1)

        await #expect(throws: ClipboardCloudError.accountChanged) {
            try await client.sync.deleteSyncedHistory(generation: accountA)
        }
        #expect(Set(try await cloud.fetch().entries.keys) == [synced.id])
        #expect((try? Data(contentsOf: client.bindingURL)) == bindingA)
        #expect(try await setAsideEntryIDs(in: client.root).isEmpty)
        #expect(try await client.store.load().entries.map(\.id) == [synced.id])
    }
    @Test func matchingAccountSyncsAsBefore() async throws {
        let cloud = ClipboardTestCloud()
        let client = ClipboardClient(cloud, accountState: ClipboardTestAccount(.available(accountLineage: "account-A")))
        defer { try? FileManager.default.removeItem(at: client.root) }
        let accountA = namespaceKey(account: "account-A", generation: UUID())
        let clip = entry("copied under account A")
        try await client.store.insert(clip); try await client.run(scope: accountA)

        #expect(Set(try await cloud.fetch().entries.keys) == [clip.id])
        #expect(try Data(contentsOf: client.bindingURL) == JSONEncoder().encode(accountA))
    }
    @Test func pinnedFilesTransferBytesAndUnpinnedReferencesStayLocal() async throws {
        let cloud = ClipboardTestCloud(); let a = ClipboardClient(cloud); let b = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        try FileManager.default.createDirectory(at: a.root, withIntermediateDirectories: true)
        let source = a.root.appendingPathComponent("example.txt"); try Data("actual file".utf8).write(to: source)
        let clip = ClipboardEntry(items: [.init(representations: [.init(type: "public.file-url", data: Data(source.absoluteString.utf8))])])
        try await a.store.insert(clip); try await a.run()
        #expect(try await b.run().entries.isEmpty)
        try await a.store.setPinned(true, id: clip.id)
        try FileManager.default.removeItem(at: source)
        try await a.run()
        let wire = try #require(try await cloud.fetch().entries[clip.id])
        let payload = try JSONDecoder().decode(ClipboardCloudPayload.self, from: wire)
        #expect(!payload.entry.fileURLs.contains { $0.path.contains(a.root.path) })
        #expect(try await a.store.load().entries.first?.hasBeenShared == true)
        let downloaded = try #require(try await b.run().entries.first)
        let file = try #require(b.files.resolvedFileURLs(for: downloaded).first)
        #expect(try Data(contentsOf: file) == Data("actual file".utf8))
        try await a.store.setPinned(false, id: clip.id); try await a.run()
        #expect(try await b.run().entries.first?.isPinned == false)
    }
    @Test func stopCancelsPendingWriteAndDeletePermitsNewGeneration() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("cancel"))
        await cloud.pauseNextSave()
        let running = Task { try await client.run() }
        for _ in 0..<10_000 {
            if await cloud.hasPaused() { break }
            await Task.yield()
        }
        #expect(await cloud.hasPaused())
        client.sync.stop(); await cloud.resumeSave()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(try await cloud.fetch().entries.isEmpty)
        try await client.run()
        try await client.sync.deleteSyncedHistory(generation: "account-generation-A")
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect(try await client.run(scope: "new-generation").entries.isEmpty)
    }
    @Test func syncAfterStopWaitsForTheStoppedRunInsteadOfReportingBusy() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let clip = entry("upload after restart")
        try await client.store.insert(clip)
        await cloud.pauseNextSave()
        let stopped = Task { try await client.run() }
        try await requireSavePaused(cloud, during: stopped)

        client.sync.stop()
        let restarted = client.startRun()
        await cloud.resumeSave()

        await #expect(throws: CancellationError.self) { try await stopped.value }
        #expect(try await restarted.value.entries.map(\.id) == [clip.id])
        #expect(Set(try await cloud.fetch().entries.keys) == [clip.id])
    }

    @Test func stopEndsASyncWaitingForTheStoppedRun() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("stays local"))
        await cloud.pauseNextSave()
        let stopped = Task { try await client.run() }
        try await requireSavePaused(cloud, during: stopped)

        client.sync.stop()
        let waiting = client.startRun()
        client.sync.stop()
        await cloud.resumeSave()

        await #expect(throws: CancellationError.self) { try await waiting.value }
        await #expect(throws: CancellationError.self) { try await stopped.value }
        #expect(await cloud.fetchCount() == 1)
        #expect(try await cloud.fetch().entries.isEmpty)
    }

    @Test func stopRevokesAnAdmissionTheWaitingSyncHasNotClaimed() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("stays local"))
        await cloud.pauseNextSave()
        // The defer runs in the main-actor turn that admits the waiting sync, before it resumes.
        let stopped = Task {
            defer { client.sync.stop() }
            try await client.run()
        }
        try await requireSavePaused(cloud, during: stopped)

        client.sync.stop()
        let waiting = client.startRun()
        await cloud.resumeSave()

        await #expect(throws: CancellationError.self) { try await stopped.value }
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(await cloud.fetchCount() == 1)
        #expect(try await cloud.fetch().entries.isEmpty)
    }

    @Test func overlappingSyncReportsBusy() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let clip = entry("in flight")
        try await client.store.insert(clip)
        await cloud.pauseNextSave()
        let running = Task { try await client.run() }
        try await requireSavePaused(cloud, during: running)

        await #expect(throws: ClipboardCloudError.busy) { try await client.run() }
        await cloud.resumeSave()

        #expect(try await running.value.entries.map(\.id) == [clip.id])
        #expect(await cloud.fetchCount() == 1)
    }

    @Test func reopenedServiceSyncsWhileTheStoppedRunUnwinds() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let clip = entry("synced after reopening")
        try await client.store.insert(clip)
        await cloud.pauseNextSave()
        let stopped = Task { try await client.run() }
        try await requireSavePaused(cloud, during: stopped)
        client.sync.stop()

        let reopened = ClipboardClient(reopening: client, cloud)
        #expect(try await reopened.run().entries.map(\.id) == [clip.id])
        await cloud.resumeSave()

        await #expect(throws: CancellationError.self) { try await stopped.value }
        let stored = try await client.store.load().entries
        #expect(stored.map { $0.id } == [clip.id])
        #expect(stored.allSatisfy { $0.hasBeenShared })
        #expect(Set(try await cloud.fetch().entries.keys) == [clip.id])
    }

    @Test func waitingSyncIsRefusedWhenItsOptInEndsBeforeAdmission() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let clip = entry("stays local")
        try await client.store.insert(clip)
        await cloud.pauseNextSave()
        let stopped = Task { try await client.run() }
        try await requireSavePaused(cloud, during: stopped)

        client.sync.stop()
        let optIn = ClipboardOptIn()
        let waiting = client.startRun(isEnabled: { optIn.isOn })
        optIn.isOn = false
        await cloud.resumeSave()

        await #expect(throws: CancellationError.self) { try await stopped.value }
        #expect(try await waiting.value.entries.map(\.id) == [clip.id])
        #expect(await cloud.fetchCount() == 1)
        #expect(try await cloud.fetch().entries.isEmpty)
    }

    @Test func runStopsWhenItsOptInEndsMidRun() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("stays local"))
        await cloud.pauseNextSave()
        let optIn = ClipboardOptIn()
        let running = client.startRun(isEnabled: { optIn.isOn })
        try await requireSavePaused(cloud, during: running)

        optIn.isOn = false
        let stopped = await eventually { !client.sync.isSyncing }
        await cloud.resumeSave()

        #expect(stopped, "The run kept syncing after its opt-in ended")
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await cloud.fetchCount() == 1)
        #expect(try await cloud.fetch().entries.isEmpty)
    }

    @Test func stoppedRunReportsCancellationWhenItsTransportFails() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("stays local"))
        await cloud.pauseNextSave(thenThrow: CKError(.operationCancelled))
        let optIn = ClipboardOptIn()
        let running = client.startRun(isEnabled: { optIn.isOn })
        try await requireSavePaused(cloud, during: running)

        optIn.isOn = false
        let stopped = await eventually { !client.sync.isSyncing }
        await cloud.resumeSave()

        #expect(stopped, "The run kept syncing after its opt-in ended")
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(client.sync.lastError == nil)
        #expect(try await cloud.fetch().entries.isEmpty)
    }

    @Test func runRechecksAnUnobservedOptInAfterItsSave() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("stays unacknowledged"))
        await cloud.pauseNextSave()
        let optIn = ClipboardUnobservedOptIn()
        let running = client.startRun(isEnabled: { optIn.isOn })
        try await requireSavePaused(cloud, during: running)

        optIn.isOn = false
        await cloud.resumeSave()

        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(!client.sync.isSyncing)
        #expect(client.sync.lastError == nil)
        #expect(await cloud.fetchCount() == 1)
        let stored = try await client.store.load().entries
        #expect(stored.count == 1)
        #expect(stored.allSatisfy { !$0.hasBeenShared })
    }

    @Test func finishedRunStopsWatchingItsOptIn() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        weak var released: ClipboardOptIn?
        do {
            let optIn = ClipboardOptIn()
            released = optIn
            try await client.run(isEnabled: { optIn.isOn })
        }
        let watchEnded = await eventually { released == nil }
        #expect(watchEnded, "The opt-in watch outlived its run")
    }

    @Test func syncWithItsOptInOffStopsTheRunBeforeWaiting() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let clip = entry("stays local")
        try await client.store.insert(clip)
        await cloud.pauseNextSave()
        let running = Task { try await client.run() }
        try await requireSavePaused(cloud, during: running)

        let disabled = client.startRun(isEnabled: { false })
        #expect(!client.sync.isSyncing)
        await cloud.resumeSave()

        #expect(try await disabled.value.entries.map(\.id) == [clip.id])
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await cloud.fetchCount() == 1)
        #expect(try await cloud.fetch().entries.isEmpty)
    }

    @Test func rejectsOversizedPinnedPayloadBeforeUpload() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let huge = ClipboardEntry(items: [.init(representations: [.init(type: "public.png", data: Data(count: ClipboardHistoryState.entryByteLimit + 1))])], pinnedAt: Date())
        try await client.store.insert(huge)
        await #expect(throws: ClipboardCloudError.payloadTooLarge) { try await client.run() }
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect(try await client.store.load().entries.count == 1)
    }

    @Test func sameNamedFilesStayDistinctAndRepeatCaptureDeduplicates() async throws {
        let cloud = ClipboardTestCloud(); let a = ClipboardClient(cloud); let b = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        var originals: [ClipboardEntry] = []
        for folder in ["one", "two"] {
            let directory = a.root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = directory.appendingPathComponent("report.txt")
            try Data(folder.utf8).write(to: source)
            let clip = ClipboardEntry(items: [.init(representations: [.init(type: "public.file-url", data: Data(source.absoluteString.utf8))])])
            originals.append(clip)
            try await a.store.insert(clip); try await a.store.setPinned(true, id: clip.id)
        }
        try await a.run()
        let downloaded = try await b.run()
        #expect(downloaded.entries.count == 2)
        #expect(Set(downloaded.entries.map(\.fingerprint)) == Set(originals.map(\.fingerprint)))
        try await a.run()
        let original = try #require(originals.first)
        try await a.store.insert(ClipboardEntry(items: original.items))
        #expect(try await a.store.load().entries.count == 2)
    }

    @Test func neverSyncedHistorySurvivesAccountResetAndCloudDeletion() async throws {
        let client = ClipboardClient(ClipboardTestCloud())
        defer { try? FileManager.default.removeItem(at: client.root) }
        let local = entry("local pin", pinned: true)
        try await client.store.insert(local)
        var settingAsideCalls = 0
        try await client.sync.resetAccountBinding(settingAside: { settingAsideCalls += 1 })
        #expect(settingAsideCalls == 0)
        #expect(try await setAsideEntryIDs(in: client.root) == [])
        #expect(try await client.store.load().entries.map(\.id) == [local.id])
        try await client.sync.deleteSyncedHistory(generation: "account-generation-A")
        try await client.sync.deleteSyncedHistory(generation: "account-generation-A")
        #expect(try await client.store.load().entries.map(\.id) == [local.id])
    }

    @Test func accountResetIncludingUnboundHistorySetsItAside() async throws {
        let client = ClipboardClient(ClipboardTestCloud())
        defer { try? FileManager.default.removeItem(at: client.root) }
        let local = entry("never synced")
        try await client.store.insert(local)
        var settingAsideCalls = 0
        try await client.sync.resetAccountBinding(includingUnboundHistory: true, settingAside: { settingAsideCalls += 1 })
        #expect(settingAsideCalls == 1)
        #expect(try await setAsideEntryIDs(in: client.root) == [[local.id]])
        #expect(try await client.store.load().entries.isEmpty)
    }

    @Test func accountResetStopsWhenSettingAsideThrows() async throws {
        struct SettingAsideFailure: Error {}
        let client = ClipboardClient(ClipboardTestCloud())
        defer { try? FileManager.default.removeItem(at: client.root) }
        let bindingURL = client.root.appendingPathComponent("clipboard-account-binding.json")
        let synced = entry("synced")
        try await client.store.insert(synced); try await client.run()
        let binding = try Data(contentsOf: bindingURL)

        await #expect(throws: SettingAsideFailure.self) {
            try await client.sync.resetAccountBinding(settingAside: { throw SettingAsideFailure() })
        }

        #expect(try Data(contentsOf: bindingURL) == binding)
        #expect(try await client.store.load().entries.map(\.id) == [synced.id])
        #expect(try await setAsideEntryIDs(in: client.root) == [])
    }

    @Test func failedAccountResetKeepsUnboundHistoryOutOfTheNextAccount() async throws {
        struct SettingAsideFailure: Error {}
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let bindingURL = client.root.appendingPathComponent("clipboard-account-binding.json")
        let older = entry("never synced")
        try await client.store.insert(older)

        await #expect(throws: SettingAsideFailure.self) {
            try await client.sync.resetAccountBinding(includingUnboundHistory: true,
                                                      settingAside: { throw SettingAsideFailure() })
        }
        await #expect(throws: ClipboardCloudError.syncGenerationChanged) {
            try await client.run(scope: "account-generation-B")
        }
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect(try Data(contentsOf: bindingURL) == JSONEncoder().encode("clipboard-reset-pending"))

        try await client.sync.resetAccountBinding()
        #expect(try await setAsideEntryIDs(in: client.root) == [[older.id]])
        #expect(try await client.store.load().entries.isEmpty)

        try await client.run(scope: "account-generation-B")
        #expect(try await cloud.fetch().entries.isEmpty)
    }

    @Test func busyAccountResetKeepsUnboundHistoryOutOfTheNextAccount() async throws {
        let clock = ClipboardRetryClock()
        let sleep = ClipboardRetrySleepGate()
        let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { duration in
            try await sleep.wait()
            clock.advance(duration)
        })
        let cloud = ClipboardTestCloud()
        await cloud.rateLimitDeletes(1)
        let client = ClipboardClient(cloud, retry: retry)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let bindingURL = client.root.appendingPathComponent("clipboard-account-binding.json")
        let older = entry("never synced")
        try await client.store.insert(older)
        let deleting = Task { try await client.sync.deleteSyncedHistory(generation: "account-generation-A") }

        let waiting = await eventually { sleep.isWaiting }
        if !waiting { deleting.cancel() }
        try #require(waiting, "The cloud delete retry never waited")
        await #expect(throws: ClipboardCloudError.busy) {
            try await client.sync.resetAccountBinding(includingUnboundHistory: true)
        }
        sleep.release()
        try await deleting.value

        await #expect(throws: ClipboardCloudError.syncGenerationChanged) {
            try await client.run(scope: "account-generation-B")
        }
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect(try Data(contentsOf: bindingURL) == JSONEncoder().encode("clipboard-reset-pending"))

        try await client.sync.resetAccountBinding()
        #expect(try await setAsideEntryIDs(in: client.root) == [[older.id]])
        #expect(try await client.store.load().entries.isEmpty)

        try await client.run(scope: "account-generation-B")
        #expect(try await cloud.fetch().entries.isEmpty)
    }

    @Test func failedAccountResetBlocksTheNextAccountAfterARelaunch() async throws {
        struct SettingAsideFailure: Error {}
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let bindingURL = client.root.appendingPathComponent("clipboard-account-binding.json")
        let bindingB = try JSONEncoder().encode("account-generation-B")
        let older = entry("never synced")
        try await client.store.insert(older)
        await #expect(throws: SettingAsideFailure.self) {
            try await client.sync.resetAccountBinding(includingUnboundHistory: true,
                                                      settingAside: { throw SettingAsideFailure() })
        }

        let relaunched = ClipboardClient(reopening: client, cloud)
        await #expect(throws: ClipboardCloudError.syncGenerationChanged) {
            try await relaunched.run(scope: "account-generation-B")
        }
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect((try? Data(contentsOf: bindingURL)) != bindingB)

        try await relaunched.sync.resetAccountBinding()
        #expect(try await setAsideEntryIDs(in: client.root) == [[older.id]])
        #expect(try await relaunched.store.load().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bindingURL.path))

        try await relaunched.run(scope: "account-generation-B")
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect(try Data(contentsOf: bindingURL) == bindingB)
    }

    @Test func accountResetBusyBehindAnotherResetBlocksTheNextAccountAfterARelaunch() async throws {
        struct SettingAsideFailure: Error {}
        let gate = ClipboardRetrySleepGate()
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let bindingURL = client.root.appendingPathComponent("clipboard-account-binding.json")
        let bindingB = try JSONEncoder().encode("account-generation-B")
        let older = entry("never synced")
        try await client.store.insert(older)
        let holding = Task {
            try await client.sync.resetAccountBinding(includingUnboundHistory: true, settingAside: {
                try await gate.wait()
                throw SettingAsideFailure()
            })
        }

        let held = await eventually { gate.isWaiting }
        if !held { holding.cancel() }
        try #require(held, "The first reset never reached its set-aside")
        await #expect(throws: ClipboardCloudError.busy) {
            try await client.sync.resetAccountBinding(includingUnboundHistory: true)
        }

        let relaunched = ClipboardClient(reopening: client, cloud)
        await #expect(throws: ClipboardCloudError.syncGenerationChanged) {
            try await relaunched.run(scope: "account-generation-B")
        }
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect((try? Data(contentsOf: bindingURL)) != bindingB)

        // The first reset fails without setting anything aside, as if its process ended.
        gate.release()
        await #expect(throws: SettingAsideFailure.self) { try await holding.value }

        try await relaunched.sync.resetAccountBinding()
        #expect(try await setAsideEntryIDs(in: client.root) == [[older.id]])
        #expect(try await relaunched.store.load().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bindingURL.path))

        try await relaunched.run(scope: "account-generation-B")
        #expect(try await cloud.fetch().entries.isEmpty)
    }

    @Test func accountResetBusyBehindADeleteBlocksTheNextAccountAfterARelaunch() async throws {
        let clock = ClipboardRetryClock()
        let sleep = ClipboardRetrySleepGate()
        let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { duration in
            try await sleep.wait()
            clock.advance(duration)
        })
        let cloud = ClipboardTestCloud()
        await cloud.rateLimitDeletes(1)
        let client = ClipboardClient(cloud, retry: retry)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let bindingURL = client.root.appendingPathComponent("clipboard-account-binding.json")
        let bindingB = try JSONEncoder().encode("account-generation-B")
        let older = entry("never synced")
        try await client.store.insert(older)
        let deleting = Task { try await client.sync.deleteSyncedHistory(generation: "account-generation-A") }

        let waiting = await eventually { sleep.isWaiting }
        if !waiting { deleting.cancel() }
        try #require(waiting, "The cloud delete retry never waited")
        await #expect(throws: ClipboardCloudError.busy) {
            try await client.sync.resetAccountBinding(includingUnboundHistory: true)
        }
        sleep.release()
        try await deleting.value

        let relaunched = ClipboardClient(reopening: client, cloud)
        await #expect(throws: ClipboardCloudError.syncGenerationChanged) {
            try await relaunched.run(scope: "account-generation-B")
        }
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect((try? Data(contentsOf: bindingURL)) != bindingB)

        try await relaunched.sync.resetAccountBinding()
        #expect(try await setAsideEntryIDs(in: client.root) == [[older.id]])
        #expect(try await relaunched.store.load().entries.isEmpty)

        try await relaunched.run(scope: "account-generation-B")
        #expect(try await cloud.fetch().entries.isEmpty)
    }

    @Test func newerResetKeepsTheMarkerWhenAnEarlierResetFinishes() async throws {
        let gate = ClipboardRetrySleepGate()
        let cloud = ClipboardTestCloud()
        let client = ClipboardClient(cloud, resetStep: { step in
            if step == .historyCleared { try await gate.wait() }
        })
        defer { try? FileManager.default.removeItem(at: client.root) }
        let bindingURL = client.root.appendingPathComponent("clipboard-account-binding.json")
        let bindingB = try JSONEncoder().encode("account-generation-B")
        let marker = try JSONEncoder().encode("clipboard-reset-pending")
        let older = entry("never synced")
        try await client.store.insert(older)
        let first = Task { try await client.sync.resetAccountBinding(includingUnboundHistory: true) }

        let held = await eventually { gate.isWaiting }
        if !held { first.cancel() }
        try #require(held, "The first reset never cleared history")
        let newer = entry("copied during the first reset")
        try await client.store.insert(newer)
        await #expect(throws: ClipboardCloudError.busy) {
            try await client.sync.resetAccountBinding(includingUnboundHistory: true)
        }
        gate.release()
        try await first.value
        #expect((try? Data(contentsOf: bindingURL)) == marker)

        let relaunched = ClipboardClient(reopening: client, cloud)
        await #expect(throws: ClipboardCloudError.syncGenerationChanged) {
            try await relaunched.run(scope: "account-generation-B")
        }
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect((try? Data(contentsOf: bindingURL)) != bindingB)

        try await relaunched.sync.resetAccountBinding()
        #expect(Set(try await setAsideEntryIDs(in: client.root)) == [[older.id], [newer.id]])
        #expect(try await relaunched.store.load().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bindingURL.path))

        try await relaunched.run(scope: "account-generation-B")
        #expect(try await cloud.fetch().entries.isEmpty)
    }

    @Test(arguments: ClipboardSetAsideCrash.allCases)
    func relaunchAfterAnInterruptedSetAsideBlocksTheNextAccount(_ crash: ClipboardSetAsideCrash) async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let bindingURL = client.root.appendingPathComponent("clipboard-account-binding.json")
        let bindingB = try JSONEncoder().encode("account-generation-B")
        let older = entry("never synced")
        try await client.store.insert(older)

        // What an interrupted unbound set-aside leaves on disk: the reset marker and a copy.
        let marker = try JSONEncoder().encode("clipboard-reset-pending")
        try marker.write(to: bindingURL, options: .atomic)
        let copy = client.root.appendingPathComponent("clipboard-quarantine-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: client.store.url, to: copy)
        if crash == .afterEmptySave { try await client.store.save(ClipboardHistoryState()) }

        let relaunched = ClipboardClient(reopening: client, cloud)
        await #expect(throws: ClipboardCloudError.syncGenerationChanged) {
            try await relaunched.run(scope: "account-generation-B")
        }
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect(try Data(contentsOf: bindingURL) == marker)

        try await relaunched.sync.resetAccountBinding()
        #expect(!FileManager.default.fileExists(atPath: bindingURL.path))
        #expect(try await ClipboardHistoryStore(url: copy).load().entries.map(\.id) == [older.id])
        #expect(try await relaunched.store.load().entries.isEmpty)

        try await relaunched.run(scope: "account-generation-B")
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect(try Data(contentsOf: bindingURL) == bindingB)
    }

    @Test func resetMarkerIsAStringNoOlderBuildReadsAsABinding() async throws {
        struct SettingAsideFailure: Error {}
        let client = ClipboardClient(ClipboardTestCloud())
        defer { try? FileManager.default.removeItem(at: client.root) }
        let bindingURL = client.root.appendingPathComponent("clipboard-account-binding.json")
        try await client.store.insert(entry("never synced"))
        await #expect(throws: SettingAsideFailure.self) {
            try await client.sync.resetAccountBinding(includingUnboundHistory: true,
                                                      settingAside: { throw SettingAsideFailure() })
        }

        // Every build since #138 decodes the binding file as a JSON string.
        let stored = try JSONDecoder().decode(String.self, from: Data(contentsOf: bindingURL))
        #expect(stored == "clipboard-reset-pending")
        // Builds from #340 classify a string that isn't a namespace key as another account.
        #expect(ICloudSyncNamespaceBinding(namespaceKey: CloudSyncNamespaceKey(rawValue: stored)) == nil)
    }

    @Test func accountResetIncludingUnboundHistoryLeavesNoBindingFile() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        let bindingURL = client.root.appendingPathComponent("clipboard-account-binding.json")
        try await client.store.insert(entry("never synced"))

        try await client.sync.resetAccountBinding(includingUnboundHistory: true)
        #expect(!FileManager.default.fileExists(atPath: bindingURL.path))

        try await client.run(scope: "account-generation-B")
        #expect(try await cloud.fetch().entries.isEmpty)
        #expect(try Data(contentsOf: bindingURL) == JSONEncoder().encode("account-generation-B"))
    }

    @Test func unchangedSyncDoesNotWriteAnotherManifest() async throws {
        let cloud = ClipboardTestCloud(); let client = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: client.root) }
        try await client.store.insert(entry("unchanged"))
        try await client.run()
        let first = try await cloud.fetch().version
        try await client.run(); try await client.run()
        #expect(try await cloud.fetch().version == first)
    }

    @Test func payloadWorkerReusesUnchangedFilesAndEncoding() async throws {
        let client = ClipboardClient(ClipboardTestCloud())
        defer { try? FileManager.default.removeItem(at: client.root) }
        let file = ClipboardOwnedFile(id: UUID(), name: "sample.txt", relativePath: "sample.txt")
        var clip = entry("file", pinned: true)
        clip.ownedFiles = [file]; clip.hasBeenShared = true
        let bytes = try JSONEncoder().encode(ClipboardCloudPayload(entry: clip, files: [file.id: Data("sample".utf8)]))
        let remote = ClipboardCloudSnapshot(entries: [clip.id: bytes])
        let worker = ClipboardPayloadWorker(store: client.store, files: client.files)
        _ = try await worker.prepare(remote, cancellation: ClipboardCloudCancellation())
        let decodes = await worker.decodeCount, encodes = await worker.encodeCount, imports = await worker.importCount
        _ = try await worker.prepare(remote, cancellation: ClipboardCloudCancellation())
        #expect(await worker.decodeCount == decodes)
        #expect(await worker.encodeCount == encodes)
        #expect(await worker.importCount == imports)
        #expect(try Data(contentsOf: client.files.url(for: file)) == Data("sample".utf8))
    }

    @Test func localFileReferencesDoNotEvictSharedHistory() async throws {
        let cloud = ClipboardTestCloud(); let a = ClipboardClient(cloud); let b = ClipboardClient(cloud)
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        let shared = entry("shared text")
        try await a.store.insert(shared); try await a.run()
        for index in 0..<100 {
            try await b.store.insert(ClipboardEntry(items: [.init(representations: [
                .init(type: "public.file-url", data: Data("file:///local-\(index).txt".utf8))
            ])]))
        }
        try await b.run()
        #expect(try await a.run().entries.map(\.id) == [shared.id])
        #expect(try await b.store.load().entries.count == 101)
    }

}

private final class ClipboardRetryClock: Sendable {
    private let origin = ContinuousClock.now
    private let value = Mutex<Duration>(.zero)
    var now: ContinuousClock.Instant { origin.advanced(by: elapsed) }
    var elapsed: Duration { value.withLock { $0 } }
    func advance(_ duration: Duration) { value.withLock { $0 += duration } }
}

private final class ClipboardRetrySleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    var isWaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        return continuation != nil
    }

    func wait() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = lock.withLock {
                    if Task.isCancelled { return true }
                    self.continuation = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        }, onCancel: {
            self.cancelWaiter()
        })
    }

    func release() {
        takeContinuation()?.resume()
    }

    func cancelWaiter() {
        takeContinuation()?.resume(throwing: CancellationError())
    }

    private func takeContinuation() -> CheckedContinuation<Void, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
