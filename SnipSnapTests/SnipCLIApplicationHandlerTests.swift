import AppKit
import Foundation
import SnipSnapCore
import SwiftUI
import XCTest
@testable import SnipSnap

final class SnipCLIApplicationHandlerTests: StoreBackedTestCase {
    @MainActor
    func testOriginSettingsSnapshotRevisionCompatibilityAndEditingGuard() async throws {
        let snip = Snip(content: "Manual draft", origin: .quickEntry)
        let model = AppModel(library: InMemorySnipLibrary(snips: [snip]), defaults: defaults())
        await model.waitForInitialLoad()
        let handler = makeHandler(model: model)
        func settings() async throws -> SnipCLIApplicationResult {
            let receipt = try await handle(.settingsShow, using: handler, model: model)
            guard case .application(let result) = receipt.extendedResult else {
                throw SnipLibraryError.invalidCommand
            }
            return result
        }
        let initial = try await settings()
        XCTAssertEqual(initial.values["origin-filter"], "all")
        _ = try await handle(.setSetting(key: .originFilter, value: "human", expectedRevision: initial.revision),
                             using: handler, model: model)
        let human = try await settings()
        XCTAssertEqual(human.values["origin-filter"], "human")
        XCTAssertEqual(human.values["agent-snips-only"], "off")
        XCTAssertNotEqual(human.revision, initial.revision)
        do {
            _ = try await handle(.setSetting(key: .originFilter, value: "agent", expectedRevision: initial.revision),
                                 using: handler, model: model)
            XCTFail("The previous filter revision must be stale.")
        } catch {}
        XCTAssertEqual(model.originFilter, .human)
        _ = try await handle(.setSetting(key: .agentSnipsOnly, value: "on", expectedRevision: human.revision),
                             using: handler, model: model)
        let agent = try await settings()
        XCTAssertEqual(agent.values["origin-filter"], "agent")
        XCTAssertEqual(agent.values["agent-snips-only"], "on")
        _ = try await handle(.setSetting(key: .agentSnipsOnly, value: "off", expectedRevision: agent.revision),
                             using: handler, model: model)
        let all = try await settings()
        XCTAssertEqual(all.values["origin-filter"], "all")
        let opened = await model.beginEditing(snip.id)
        XCTAssertTrue(opened)
        for key in [SnipCLIApplicationSetting.originFilter, .agentSnipsOnly] {
            do {
                _ = try await handle(.setSetting(key: key, value: key == .originFilter ? "human" : "on",
                                                expectedRevision: all.revision), using: handler, model: model)
                XCTFail("Changing origin must preserve the inline editor.")
            } catch SnipCLIRequestError.editingInProgress {}
        }
        XCTAssertEqual(model.originFilter, .all)
    }

    @MainActor
    func testICloudRetryRejectsAnEditorWithoutReplacingItsLibrary() async throws {
        let snip = Snip(content: "Draft being edited", origin: .quickEntry)
        let model = AppModel(library: InMemorySnipLibrary(snips: [snip]), defaults: defaults())
        await model.waitForInitialLoad()
        let beganEditing = await model.beginEditing(snip.id)
        XCTAssertTrue(beganEditing)
        let originalScope = model.cliScopeToken
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let cloud = ApplicationCLICloudEffects {
            try await settings.performExplicitSyncWithOutcome { _ in
                await model.replaceLibrary(InMemorySnipLibrary(snips: []),
                                           recoveryScope: SnipRecoveryScope("replacement"))
                return .finished(.libraryReplaced, .applied)
            }
        }
        let handler = makeHandler(model: model, cloud: cloud, syncSettings: settings)

        do {
            _ = try await handle(.retrySync, using: handler, model: model)
            XCTFail("Retry must preserve the open editor, including when iCloud sync is already enabled.")
        } catch SnipCLIRequestError.editingInProgress {}

        XCTAssertEqual(model.editingID, snip.id)
        XCTAssertEqual(model.cliScopeToken, originalScope)
        XCTAssertEqual(model.filteredSnips.map(\.content), ["Draft being edited"])
    }

    @MainActor
    func testRetryReservesEditingUntilReplacementAndReturnsTheResultingScope() async throws {
        let snip = Snip(content: "Original", origin: .quickEntry)
        let model = AppModel(library: InMemorySnipLibrary(snips: [snip]), defaults: defaults())
        await model.waitForInitialLoad()
        let gate = ApplicationCLITransitionGate()
        let replacement = Snip(content: "Downloaded collection", origin: .quickEntry)
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let cloud = ApplicationCLICloudEffects {
            try await settings.performExplicitSyncWithOutcome { _ in
                await gate.suspend()
                await model.replaceLibrary(InMemorySnipLibrary(snips: [replacement]),
                                           recoveryScope: SnipRecoveryScope("downloaded"))
                return .finished(.libraryReplaced, .applied)
            }
        }
        let handler = makeHandler(model: model, cloud: cloud, syncSettings: settings)
        let request = SnipCLIRequest(action: .extended(.application(.retrySync)), scopeToken: model.cliScopeToken)
        let retry = Task { try await handler.handle(request, action: .retrySync) }
        await gate.waitUntilEntered()

        let beganEditing = await model.beginEditing(snip.id)
        XCTAssertFalse(beganEditing)
        XCTAssertNil(model.editingID)
        do {
            _ = try await handle(.search(query: "Must wait"), using: handler, model: model)
            XCTFail("Search must wait for the reserved scope transition.")
        } catch SnipLibraryError.modeTransitionInProgress {}
        XCTAssertEqual(model.query, "")
        gate.resume()
        let receipt = try await retry.value

        XCTAssertEqual(receipt.status, .success)
        XCTAssertEqual(receipt.scopeToken, request.scopeToken)
        XCTAssertNotEqual(receipt.resultingScopeToken, request.scopeToken)
        XCTAssertEqual(receipt.resultingScopeToken, model.cliScopeToken)
        XCTAssertEqual(model.filteredSnips.map(\.content), ["Downloaded collection"])
        let beganEditingAfterRetry = await model.beginEditing(replacement.id)
        XCTAssertTrue(beganEditingAfterRetry, "The reservation must end after replacement finishes.")
    }

    @MainActor
    func testRetryOfAnIncompleteDeletionRunsTheRetry() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        await model.waitForInitialLoad()
        let retries = ApplicationCLIRetryCounter()
        let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
        let handler = makeHandler(
            model: model, cloud: ApplicationCLICloudEffects {
                try await settings.performExplicitSyncWithOutcome { _ in
                    retries.record()
                    return .finished(.noChange, .notRequired)
                }
            }, syncSettings: settings
        )

        let receipt = try await handle(.retrySync, using: handler, model: model)

        XCTAssertEqual(retries.count, 1)
        XCTAssertEqual(receipt.status, .success)
    }

    @MainActor
    func testFailedRetryOfAnIncompleteDeletionReportsFailure() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        await model.waitForInitialLoad()
        let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
        let cloud = ApplicationCLICloudEffects {
            try await settings.performExplicitSyncWithOutcome { _ in
                settings.recordSyncFailure(.waitingForConnection)
                return .finished(.syncIssue(.waitingForConnection), .notRequired)
            }
        }
        let handler = makeHandler(model: model, cloud: cloud, syncSettings: settings)

        let receipt = try await handle(.retrySync, using: handler, model: model)

        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.message, settings.detail)
    }

    @MainActor
    func testRetryThatLeavesADeletionIncompleteReportsFailure() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        await model.waitForInitialLoad()
        let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
        let cloud = ApplicationCLICloudEffects {
            try await settings.performExplicitSyncWithOutcome { _ in
                settings.recordRemovalPending()
                return .finished(.oldSyncedContentRemovalPending, .notRequired)
            }
        }
        let handler = makeHandler(model: model, cloud: cloud, syncSettings: settings)

        let receipt = try await handle(.retrySync, using: handler, model: model)

        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.message, settings.detail)
    }

    @MainActor
    func testRetryThatFinishesADeletionAfterAFailureReportsSuccess() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        await model.waitForInitialLoad()
        let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
        // Like the Mac app's sync, the retry takes its start before any result arrives.
        let cloud = ApplicationCLICloudEffects {
            try await settings.performExplicitSyncWithOutcome { _ in
                let start = settings.recordSyncStarted()
                settings.recordSyncFailure(.waitingForConnection)
                settings.recordSyncCompleted(start)
                return .finished(.oldSyncedContentRemovalCompleted, .notRequired)
            }
        }
        let handler = makeHandler(model: model, cloud: cloud, syncSettings: settings)

        let receipt = try await handle(.retrySync, using: handler, model: model)

        XCTAssertEqual(settings.state, .deleted)
        XCTAssertEqual(receipt.status, .success)
    }

    @MainActor
    func testRetryThatTurnsSyncBackOnIgnoresAnEarlierFailedDeletionRetry() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        await model.waitForInitialLoad()
        let settings = SyncedContentSettingsModel(
            mode: .iCloudSync, initialState: .removalPending, enableAction: { .enabled }
        )
        await settings.performExplicitSync { settings.recordSyncFailure(.waitingForConnection) }
        XCTAssertEqual(settings.finishDeletingIssue, .waitingForConnection)
        settings.recordSyncStopped(.signInRequired)
        let handler = makeHandler(model: model, syncSettings: settings)

        let receipt = try await handle(.retrySync, using: handler, model: model)

        XCTAssertEqual(settings.mode, .iCloudSync)
        XCTAssertEqual(settings.state, .ready)
        XCTAssertEqual(receipt.status, .success)
    }

    @MainActor
    func testRetryWhileADeleteRunsStillRefuses() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        await model.waitForInitialLoad()
        let retries = ApplicationCLIRetryCounter()
        let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .deleting)
        let handler = makeHandler(
            model: model, cloud: ApplicationCLICloudEffects {
                try await settings.performExplicitSyncWithOutcome { _ in
                    retries.record()
                    return .finished(.noChange, .notRequired)
                }
            }, syncSettings: settings
        )

        do {
            _ = try await handle(.retrySync, using: handler, model: model)
            XCTFail("A running delete must report its own outcome.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "iCloud sync is busy or unavailable. Check sync status.")
        }

        XCTAssertEqual(retries.count, 0)
    }

    @MainActor
    func testRetryDuringASettingsRetryReportsBusyWithoutAnAdditionalRetry() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        let work = ApplicationCLINoRunOwnership()
        work.retain(model)
        let loading = work.start { await model.waitForInitialLoad() }
        guard await work.ready(loading.finished, "initial model load") else {
            await work.cleanUp()
            return
        }
        let retries = ApplicationCLIRetryCounter()
        let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
        // Like the Mac app's retry action, this retry runs only if no explicit sync is running.
        let cloud = ApplicationCLIOutcomeEffects {
            try await settings.performExplicitSyncWithOutcome { _ in
                retries.record()
                return .finished(.noChange, .notRequired)
            }
        }
        let handler = makeHandler(model: model, cloud: cloud, syncSettings: settings)
        work.retain(handler)
        let gate = work.gate()
        let settingsRetry = work.start { await settings.performExplicitSync { await gate.suspend() } }
        guard await work.ready(gate.entered, "admitted Settings retry") else {
            await work.cleanUp()
            return
        }
        let cliRetry = work.start {
            do {
                let receipt = try await self.handle(.retrySync, using: handler, model: model)
                XCTFail("A declined CLI retry must throw busy, not return a \(receipt.status) receipt.")
            } catch {
                XCTAssertEqual(error.localizedDescription, "iCloud sync is busy or unavailable. Check sync status.")
            }
        }
        let completed = await cliRetry.finished.wait(for: .seconds(2))
        XCTAssertTrue(completed, "The declined CLI retry must finish while Settings still owns admission")
        XCTAssertEqual(retries.count, 0)
        XCTAssertTrue(gate.isHeld)
        XCTAssertFalse(settingsRetry.finished.isSet, "CLI completion must not finish the admitted Settings retry")
        gate.release()
        let settingsFinished = await settingsRetry.finished.wait(for: .seconds(30))
        XCTAssertTrue(settingsFinished, "The admitted Settings retry must finish after its own gate is released")
        await work.cleanUp()
        XCTAssertEqual(retries.count, 0, "Cleanup must not reveal an additional deferred CLI retry")
    }

    @MainActor
    func testRetryReportsBusyWhenAnotherRetryWinsAdmissionAfterDispatch() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        let work = ApplicationCLINoRunOwnership()
        work.retain(model)
        let loading = work.start { await model.waitForInitialLoad() }
        guard await work.ready(loading.finished, "post-dispatch model load") else {
            await work.cleanUp()
            return
        }
        let retries = ApplicationCLIRetryCounter()
        let winners = ApplicationCLIRetryCounter()
        let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
        let callback = work.gate()
        let winner = work.gate()
        let cloud = ApplicationCLIOutcomeEffects {
            await callback.suspend()
            return try await settings.performExplicitSyncWithOutcome { _ in
                retries.record()
                return .finished(.noChange, .notRequired)
            }
        }
        let handler = makeHandler(model: model, cloud: cloud, syncSettings: settings)
        work.retain(handler)
        let request = SnipCLIRequest(action: .extended(.application(.retrySync)), scopeToken: model.cliScopeToken)
        let cliRetry = work.start {
            do {
                let receipt = try await handler.handle(request, action: .retrySync)
                XCTFail("Losing admission after dispatch must throw busy, not return a \(receipt.status) receipt.")
            } catch {
                XCTAssertEqual(error.localizedDescription, "iCloud sync is busy or unavailable. Check sync status.")
            }
        }
        guard await work.ready(callback.entered, "actual CLI retry callback before Core admission") else {
            await work.cleanUp()
            return
        }
        let settingsRetry = work.start {
            await settings.performExplicitSync {
                winners.record()
                await winner.suspend()
            }
        }
        guard await work.ready(winner.entered, "Settings wins real admission after CLI dispatch") else {
            await work.cleanUp()
            return
        }
        XCTAssertTrue(callback.isHeld)
        XCTAssertTrue(winner.isHeld)
        XCTAssertEqual(winners.count, 1)
        callback.release()
        let completed = await cliRetry.finished.wait(for: .seconds(2))
        XCTAssertTrue(completed, "CLI must report busy without awaiting the admitted Settings retry")
        XCTAssertEqual(retries.count, 0)
        XCTAssertEqual(winners.count, 1)
        XCTAssertTrue(winner.isHeld)
        XCTAssertFalse(settingsRetry.finished.isSet, "The winning retry must remain pending until its own release")
        winner.release()
        let settingsFinished = await settingsRetry.finished.wait(for: .seconds(30))
        XCTAssertTrue(settingsFinished, "The winning retry must finish after test-owned release")
        await work.cleanUp()
        XCTAssertEqual(retries.count, 0, "No CLI retry body may run after the winning retry finishes")
    }

    @MainActor
    func testRetryThroughTheSimulatedHandlerRunsOnlyTheAppRetry() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        await model.waitForInitialLoad()
        let retries = ApplicationCLIRetryCounter()
        let otherSyncs = ApplicationCLIRetryCounter()
        let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
        let cloud = SimulatedCloudSyncHandler(
            syncWhenPossible: { otherSyncs.record() },
            retrySyncWhenPossible: { retries.record() },
            retrySyncWithOutcome: {
                try await settings.performExplicitSyncWithOutcome { _ in
                    retries.record()
                    return .finished(.noChange, .notRequired)
                }
            },
            scheduleSyncAfterLocalChange: { otherSyncs.record() }
        )
        let handler = makeHandler(model: model, cloud: cloud, syncSettings: settings)

        let receipt = try await handle(.retrySync, using: handler, model: model)

        XCTAssertEqual(retries.count, 1)
        XCTAssertEqual(otherSyncs.count, 0)
        XCTAssertEqual(receipt.status, .success)
    }

    @MainActor
    func testHideLeavesAnEditListFormOpen() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        let coordinator = AppCoordinator(
            model: model, shortcutSettings: ShortcutSettings(defaults: defaults()),
            isAccessibilityTrusted: { true }, accessibilitySetupDefaults: defaults()
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)
        panel.orderFront(nil)
        defer { coordinator.hidePanel(restoringPreviousApplication: false) }
        var dismissed = false
        coordinator.presentPanelDialog(id: .editList(UUID()), title: "Edit List", onDismiss: {
            dismissed = true
        }) { Text("Unsaved list name") }
        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        let handler = makeHandler(model: model, coordinator: coordinator, panel: panel)

        do {
            _ = try await handle(.hide, using: handler, model: model)
            XCTFail("A CLI hide must leave the form and its unsaved input open.")
        } catch SnipCLIRequestError.editingInProgress {}

        XCTAssertTrue(coordinator.panelDialogs.isPresented)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(dismissed)
    }

    @MainActor
    func testFailedEnableReleasesTheReservationSoEditingCanResume() async throws {
        let snip = Snip(content: "Local draft", origin: .quickEntry)
        let model = AppModel(library: InMemorySnipLibrary(snips: [snip]), defaults: defaults())
        await model.waitForInitialLoad()
        let gate = ApplicationCLITransitionGate()
        let settings = SyncedContentSettingsModel(mode: .localOnly, enableAction: {
            await gate.suspend()
            throw SnipLibraryError.storeUnavailable
        })
        let handler = makeHandler(model: model, syncSettings: settings)
        let status = try await handle(.syncStatus, using: handler, model: model)
        guard case .application(let result) = status.extendedResult else {
            return XCTFail("Expected application status.")
        }
        let action = SnipCLIApplicationAction.setSync(
            enabled: true, useCurrentCache: false, expectedRevision: result.revision
        )
        let request = SnipCLIRequest(action: .extended(.application(action)), scopeToken: model.cliScopeToken)
        let enable = Task { try await handler.handle(request, action: action) }
        await gate.waitUntilEntered()

        let beganDuringEnable = await model.beginEditing(snip.id)
        XCTAssertFalse(beganDuringEnable)
        gate.resume()
        let receipt = try await enable.value

        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.resultingScopeToken, request.scopeToken)
        let beganAfterFailure = await model.beginEditing(snip.id)
        XCTAssertTrue(beganAfterFailure)
    }

    @MainActor
    func testSettingsChangeRejectsAPendingForm() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        let coordinator = AppCoordinator(
            model: model, shortcutSettings: ShortcutSettings(defaults: defaults()),
            isAccessibilityTrusted: { true }, accessibilitySetupDefaults: defaults()
        )
        coordinator.presentPanelDialog(id: .editList(UUID()), title: "Edit List", onDismiss: {}) {
            Text("Pending form")
        }
        defer { coordinator.hidePanel(restoringPreviousApplication: false) }
        XCTAssertTrue(model.cliDialogIsPresented())
        let handler = makeHandler(model: model, coordinator: coordinator)
        let status = try await handle(.settingsShow, using: handler, model: model)
        guard case .application(let result) = status.extendedResult else {
            return XCTFail("Expected settings status.")
        }

        do {
            _ = try await handle(.setSetting(key: .appearance, value: "dark", expectedRevision: result.revision),
                                 using: handler, model: model)
            XCTFail("A queued form must retain ownership until it closes.")
        } catch SnipCLIRequestError.editingInProgress {}

        XCTAssertEqual(model.appearance, .system)
        XCTAssertTrue(model.cliDialogIsPresented())
    }

    @MainActor
    private func makeHandler(
        model: AppModel,
        cloud: (any OptionalCloudSyncHandling)? = nil,
        syncSettings: SyncedContentSettingsModel? = nil,
        coordinator: AppCoordinator? = nil,
        panel: NSWindow? = nil
    ) -> SnipCLIApplicationHandler {
        let coordinator = coordinator ?? AppCoordinator(
            model: model, shortcutSettings: ShortcutSettings(defaults: defaults()),
            isAccessibilityTrusted: { true }, accessibilitySetupDefaults: defaults()
        )
        return SnipCLIApplicationHandler(
            model: model, coordinator: coordinator,
            syncedContentSettings: syncSettings ?? SyncedContentSettingsModel(mode: .iCloudSync),
            updates: SnipCLIApplicationUpdates(settings: UpdateChannelSettings(defaults: defaults())),
            cloudSyncHandler: cloud, accountNoticeModel: nil, panel: { panel }
        )
    }

    @MainActor
    private func handle(
        _ action: SnipCLIApplicationAction, using handler: SnipCLIApplicationHandler,
        model: AppModel
    ) async throws -> SnipCLIReceipt {
        let request = SnipCLIRequest(action: .extended(.application(action)), scopeToken: model.cliScopeToken)
        return try await handler.handle(request, action: action)
    }
}

@MainActor
private final class ApplicationCLITransitionGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { resumeWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

@MainActor
private final class ApplicationCLIRetryCounter {
    private(set) var count = 0

    func record() { count += 1 }
}

@MainActor
private final class ApplicationCLICloudEffects: OptionalCloudSyncHandling {
    let retry: @MainActor () async throws -> SyncedContentActionOutcome

    init(retry: @escaping @MainActor () async throws -> SyncedContentActionOutcome) { self.retry = retry }

    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? { nil }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {}
    func syncWhenPossible() async {}
    func retrySyncWhenPossible() async { _ = try? await retry() }
    func retrySyncWithOutcome() async throws -> SyncedContentActionOutcome { try await retry() }
    func isCloudSyncActive() async throws -> Bool { true }
    func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] { [:] }
    func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL {
        throw SnipLibraryError.attachmentCopyFailed
    }
    func clearDownloadedFiles() async throws {}
}

// A timeout ends observation only; it never releases either retry's behavior gate.
private final class ApplicationCLINoRunSignal: @unchecked Sendable {
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

    private func observe() async -> Bool {
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
            self.lock.withLock { self.waiters.removeValue(forKey: id) }?.resume(returning: false)
        }
    }

    func wait(for timeout: Duration) async -> Bool {
        if isSet { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.observe() }
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

private final class ApplicationCLINoRunGate: @unchecked Sendable {
    let entered = ApplicationCLINoRunSignal()
    private let lock = NSLock()
    private var released = false
    private var pending: CheckedContinuation<Void, Never>?
    var isHeld: Bool { entered.isSet && lock.withLock { !released } }

    func suspend() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if released { return true }
                pending = continuation
                return false
            }
            entered.fire()
            if resume { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock {
            released = true
            let continuation = pending
            pending = nil
            return continuation
        }
        continuation?.resume()
    }
}

@MainActor
private final class ApplicationCLINoRunTask {
    let finished: ApplicationCLINoRunSignal
    let task: Task<Void, Never>

    init(_ operation: @escaping @MainActor () async -> Void) {
        let completion = ApplicationCLINoRunSignal()
        finished = completion
        task = Task {
            await operation()
            completion.fire()
        }
    }
}

@MainActor
private final class ApplicationCLINoRunOwnership {
    private var gates: [ApplicationCLINoRunGate] = []
    private var tasks: [ApplicationCLINoRunTask] = []
    private var resources: [AnyObject] = []
    private var retainedAfterFailedJoin: ApplicationCLINoRunOwnership?

    func retain(_ resource: AnyObject) { resources.append(resource) }

    func gate() -> ApplicationCLINoRunGate {
        let gate = ApplicationCLINoRunGate()
        gates.append(gate)
        return gate
    }

    func start(_ operation: @escaping @MainActor () async -> Void) -> ApplicationCLINoRunTask {
        let task = ApplicationCLINoRunTask(operation)
        tasks.append(task)
        return task
    }

    func ready(_ signal: ApplicationCLINoRunSignal, _ stage: String) async -> Bool {
        let ready = await signal.wait(for: .seconds(30))
        XCTAssertTrue(ready, "No-run setup/readiness failed: \(stage)")
        return ready
    }

    func cleanUp() async {
        let cleanup = Task { @MainActor [self] in
            gates.forEach { $0.release() }
            tasks.forEach { $0.task.cancel() }
            let deadline = ContinuousClock.now + .seconds(30)
            var settled = true
            for operation in tasks {
                let joined = await operation.finished.wait(for: deadline - ContinuousClock.now)
                XCTAssertTrue(joined, "No-run cleanup could not join an owned caller")
                if joined { await operation.task.value } else { settled = false }
            }
            guard settled else {
                retainedAfterFailedJoin = self
                return
            }
            tasks.removeAll()
            gates.removeAll()
            resources.removeAll()
        }
        await cleanup.value
    }
}


extension SnipCLIApplicationHandlerTests {
    @MainActor
    func testRetryEnableAwaitsTheRealRequiredHookBeforeItsOriginalSuccessReceipt() async throws {
        let work = ApplicationCLINoRunOwnership()
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        work.retain(model)
        let loading = work.start { await model.waitForInitialLoad() }
        guard await work.ready(loading.finished, "original enable CLI model load") else {
            await work.cleanUp(); return
        }
        let enables = ApplicationCLIRetryCounter()
        let applications = ApplicationCLIRetryCounter()
        let gate = work.gate()
        let settings = SyncedContentSettingsModel(mode: .localOnly, enableAction: {
            await enables.record()
            return .enabled
        })
        settings.setEnableCompletionAction {
            applications.record()
            await gate.suspend()
        }
        work.retain(settings)
        let handler = makeHandler(model: model, syncSettings: settings)
        work.retain(handler)
        let retry = work.start {
            do {
                let receipt = try await self.handle(.retrySync, using: handler, model: model)
                XCTAssertEqual(receipt.status, .success)
                XCTAssertEqual(receipt.message, "Your snips and attachments sync through iCloud.")
                guard case .application(let current) = receipt.extendedResult else {
                    return XCTFail("Expected the existing current application result")
                }
                XCTAssertEqual(current.values["mode"], "icloud-sync")
                XCTAssertEqual(current.values["state"], "ready")
            } catch { XCTFail("Actual completed enable must succeed: \(error)") }
        }
        guard await work.ready(gate.entered, "actual required enable application") else {
            await work.cleanUp(); return
        }
        let premature = await retry.finished.wait(for: .seconds(2))
        XCTAssertFalse(premature, "CLI cannot treat a required application as optional proof")
        XCTAssertTrue(gate.isHeld)
        XCTAssertEqual(enables.count, 1)
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(settings.mode, .localOnly)
        gate.release()
        guard await work.prompt(retry.finished, "CLI original enable after required hook") else {
            await work.cleanUp(); return
        }
        await work.cleanUp()
        XCTAssertEqual(enables.count, 1)
        XCTAssertEqual(applications.count, 1)
    }

    @MainActor
    func testRetryEnableKeepsTheOriginalPendingSetupMessageAndSuccessEncoding() async throws {
        let work = ApplicationCLINoRunOwnership()
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        work.retain(model)
        let loading = work.start { await model.waitForInitialLoad() }
        guard await work.ready(loading.finished, "pending enable CLI model load") else {
            await work.cleanUp(); return
        }
        let enables = ApplicationCLIRetryCounter()
        let applications = ApplicationCLIRetryCounter()
        let settings = SyncedContentSettingsModel(mode: .localOnly, enableAction: {
            await enables.record()
            return .settingUp(.waitingForConnection)
        })
        settings.setEnableCompletionAction { applications.record() }
        work.retain(settings)
        let handler = makeHandler(model: model, syncSettings: settings)
        work.retain(handler)
        let retry = work.start {
            do {
                let receipt = try await self.handle(.retrySync, using: handler, model: model)
                XCTAssertEqual(receipt.status, .success)
                XCTAssertEqual(receipt.message, "Connect to the internet to finish setup.")
                guard case .application(let current) = receipt.extendedResult else {
                    return XCTFail("Expected current application state alongside the original operation")
                }
                XCTAssertEqual(current.values["mode"], "local-only")
                XCTAssertEqual(current.values["state"], "enabling:sync.waitingForConnection")
            } catch { XCTFail("Pending setup retains its existing operation encoding: \(error)") }
        }
        guard await work.prompt(retry.finished, "pending setup original receipt") else {
            await work.cleanUp(); return
        }
        XCTAssertEqual(enables.count, 1)
        XCTAssertEqual(applications.count, 0)
        XCTAssertEqual(settings.state, .enabling(.waitingForConnection))
        await work.cleanUp()
    }

    @MainActor
    func testRetryEnableReportsAnActualRequiredApplicationFailure() async throws {
        let work = ApplicationCLINoRunOwnership()
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        work.retain(model)
        let loading = work.start { await model.waitForInitialLoad() }
        guard await work.ready(loading.finished, "failed application CLI model load") else {
            await work.cleanUp(); return
        }
        let enables = ApplicationCLIRetryCounter()
        let applications = ApplicationCLIRetryCounter()
        let failure = ApplicationCLIOriginalFailure()
        let settings = SyncedContentSettingsModel(mode: .localOnly, issueMapper: { _ in .attachmentMissing },
            enableAction: { await enables.record(); return .enabled })
        settings.setEnableCompletionAction { applications.record(); throw failure }
        work.retain(settings)
        let handler = makeHandler(model: model, syncSettings: settings)
        work.retain(handler)
        let retry = work.start {
            do {
                let receipt = try await self.handle(.retrySync, using: handler, model: model)
                XCTAssertEqual(receipt.status, .failed, "A required application really failed")
                XCTAssertEqual(receipt.message, "Can’t read an attachment. Retry sync. If it still fails, contact support.")
                guard case .application(let current) = receipt.extendedResult else {
                    return XCTFail("Expected independently current application state")
                }
                XCTAssertEqual(current.values["mode"], "local-only")
                XCTAssertEqual(current.values["state"], "failed:sync.attachmentMissing")
            } catch { XCTFail("Existing failed-enable receipt semantics must remain: \(error)") }
        }
        guard await work.prompt(retry.finished, "failed required application receipt") else {
            await work.cleanUp(); return
        }
        XCTAssertEqual(enables.count, 1)
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(settings.state, .failed(.attachmentMissing))
        await work.cleanUp()
    }

    @MainActor
    func testRetryPreservesTheActualCoreActionErrorRatherThanReturningCurrentReadySuccess() async throws {
        let work = ApplicationCLINoRunOwnership()
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        work.retain(model)
        let loading = work.start { await model.waitForInitialLoad() }
        guard await work.ready(loading.finished, "throwing original CLI model load") else {
            await work.cleanUp(); return
        }
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        work.retain(settings)
        let failure = ApplicationCLIOriginalFailure()
        let entries = ApplicationCLIRetryCounter()
        let cloud = ApplicationCLIOutcomeEffects {
            try await settings.performExplicitSyncWithOutcome { _ in
                entries.record()
                throw failure
            }
        }
        let handler = makeHandler(model: model, cloud: cloud, syncSettings: settings)
        work.retain(handler)
        let retry = work.start {
            do {
                _ = try await self.handle(.retrySync, using: handler, model: model)
                XCTFail("The original thrown action must not be replaced by current ready state")
            } catch {
                XCTAssertTrue((error as AnyObject) === failure, "Actual original error identity must survive Core and CLI")
            }
        }
        let completed = await retry.finished.wait(for: .seconds(2))
        XCTAssertTrue(completed)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(settings.state, .syncing)
        XCTAssertFalse(settings.canSyncNow)
        await work.cleanUp()
        XCTAssertEqual(entries.count, 1)
    }

    @MainActor
    func testRetryCancellationPropagatesFromRealCoreWithoutAReceiptOrASecondAction() async throws {
        let work = ApplicationCLINoRunOwnership()
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        work.retain(model)
        let loading = work.start { await model.waitForInitialLoad() }
        guard await work.ready(loading.finished, "cancelled original CLI model load") else {
            await work.cleanUp(); return
        }
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        work.retain(settings)
        let gate = work.gate()
        let entries = ApplicationCLIRetryCounter()
        let cloud = ApplicationCLIOutcomeEffects {
            try await settings.performExplicitSyncWithOutcome { _ in
                entries.record()
                await gate.suspend()
                try Task.checkCancellation()
                return .finished(.noChange, .notRequired)
            }
        }
        let handler = makeHandler(model: model, cloud: cloud, syncSettings: settings)
        work.retain(handler)
        let retry = work.start {
            do {
                _ = try await self.handle(.retrySync, using: handler, model: model)
                XCTFail("Cancellation before an original result must not return a receipt")
            } catch is CancellationError {}
            catch { XCTFail("Expected actual caller cancellation: \(error)") }
        }
        guard await work.ready(gate.entered, "real Core CLI body before cancellation") else {
            await work.cleanUp(); return
        }
        retry.task.cancel()
        XCTAssertTrue(gate.isHeld)
        XCTAssertFalse(retry.finished.isSet)
        XCTAssertEqual(entries.count, 1)
        gate.release()
        guard await work.prompt(retry.finished, "original CLI cancellation extracted") else {
            await work.cleanUp(); return
        }
        XCTAssertFalse(settings.canSyncNow)
        XCTAssertEqual(settings.state, .syncing)
        await work.cleanUp()
        XCTAssertEqual(entries.count, 1)
    }
}

private final class ApplicationCLIOriginalFailure: Error, @unchecked Sendable {}

@MainActor
private final class ApplicationCLIOutcomeEffects: OptionalCloudSyncHandling {
    private let retry: @MainActor () async throws -> SyncedContentActionOutcome

    init(_ retry: @escaping @MainActor () async throws -> SyncedContentActionOutcome) { self.retry = retry }

    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? { nil }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {}
    func syncWhenPossible() async {}
    func retrySyncWhenPossible() async { _ = try? await retry() }
    func retrySyncWithOutcome() async throws -> SyncedContentActionOutcome { try await retry() }
    func isCloudSyncActive() async throws -> Bool { true }
    func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] { [:] }
    func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL {
        throw SnipLibraryError.transferUnsupported
    }
    func clearDownloadedFiles() async throws {}
}

@MainActor
private extension ApplicationCLINoRunOwnership {
    func prompt(_ signal: ApplicationCLINoRunSignal, _ stage: String) async -> Bool {
        let completed = await signal.wait(for: .seconds(2))
        XCTAssertTrue(completed, "Original-outcome completion exceeded prompt budget: \(stage)")
        return completed
    }
}


// These cases test CLI projection from actual Core admission, not Session/application provenance.
extension SnipCLIApplicationHandlerTests {
    @MainActor
    func testRetryUsesTheCoreOriginalResultValuedIssueSeparatelyFromCurrentStartedState() async {
        await checkCLIOriginalProjection(initial: .ready,
            returning: .finished(.syncIssue(.waitingForConnection), .notRequired), failed: true,
            message: "Your changes will sync when you’re back online.", currentState: "syncing")
    }

    @MainActor
    func testRetryUsesTheCoreOriginalRemovalIssueWithTheGenericMessage() async {
        await checkCLIOriginalProjection(initial: .removalPending,
            returning: .finished(.syncIssue(.waitingForConnection), .notRequired), failed: true,
            message: "Some synced content is still in iCloud. This device keeps a recovery copy.",
            currentState: "removal-pending")
    }

    @MainActor
    func testRetryUsesItsCoreOriginalRemovalCompletionWithoutCompletingCurrentState() async {
        await checkCLIOriginalProjection(initial: .removalPending,
            returning: .finished(.noChange, .notRequired), failed: false,
            message: "This device keeps a recovery copy.", currentState: "removal-pending")
    }

    @MainActor
    private func checkCLIOriginalProjection(
        initial: SyncedContentSettingsState, returning raw: SyncedContentOriginalActionReturn,
        failed: Bool, message: String, currentState: String
    ) async {
        let work = ApplicationCLINoRunOwnership()
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        work.retain(model)
        let loading = work.start { await model.waitForInitialLoad() }
        guard await work.ready(loading.finished, "Core original projection CLI model load") else {
            await work.cleanUp(); return
        }
        let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: initial)
        work.retain(settings)
        let entries = ApplicationCLIRetryCounter()
        let cloud = ApplicationCLIOutcomeEffects {
            try await settings.performExplicitSyncWithOutcome { _ in
                entries.record()
                return raw
            }
        }
        let handler = makeHandler(model: model, cloud: cloud, syncSettings: settings)
        work.retain(handler)
        let retry = work.start {
            do {
                let receipt = try await self.handle(.retrySync, using: handler, model: model)
                XCTAssertEqual(receipt.status, failed ? .failed : .success)
                XCTAssertEqual(receipt.message, message)
                guard case .application(let current) = receipt.extendedResult else {
                    return XCTFail("Expected the separate current application result")
                }
                XCTAssertEqual(current.values["mode"], "icloud-sync")
                XCTAssertEqual(current.values["state"], currentState)
            } catch { XCTFail("A real Core projected operation must keep its receipt semantics: \(error)") }
        }
        guard await work.prompt(retry.finished, "original Core operation to CLI receipt") else {
            await work.cleanUp(); return
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(settings.finishDeletingIssue, "Raw original input cannot impersonate a live consumer issue")
        await work.cleanUp()
        XCTAssertEqual(entries.count, 1)
    }
}
