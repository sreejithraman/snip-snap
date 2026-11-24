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
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The state changed. Read its status again and use the latest revision with a new request ID."
            )
        }
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
        let cloud = ApplicationCLICloudEffects {
            await model.replaceLibrary(InMemorySnipLibrary(snips: []),
                                       recoveryScope: SnipRecoveryScope("replacement"))
        }
        let handler = makeHandler(model: model, cloud: cloud)

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
        let cloud = ApplicationCLICloudEffects {
            await gate.suspend()
            await model.replaceLibrary(InMemorySnipLibrary(snips: [replacement]),
                                       recoveryScope: SnipRecoveryScope("downloaded"))
        }
        let handler = makeHandler(model: model, cloud: cloud)
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
    func testFailedRetryReportsFailure() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        await model.waitForInitialLoad()
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let cloud = ApplicationCLICloudEffects {
            await settings.performExplicitSync { settings.recordSyncFailure(.waitingForConnection) }
        }
        let handler = makeHandler(model: model, cloud: cloud, syncSettings: settings)

        let receipt = try await handle(.retrySync, using: handler, model: model)

        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.message, settings.detail)
    }

    @MainActor
    func testRetryWhileSyncTurnsOffStillRefuses() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        await model.waitForInitialLoad()
        let retries = ApplicationCLIRetryCounter()
        let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .disabling)
        let handler = makeHandler(
            model: model, cloud: ApplicationCLICloudEffects { retries.record() }, syncSettings: settings
        )

        do {
            _ = try await handle(.retrySync, using: handler, model: model)
            XCTFail("Turning sync off must report its own outcome.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "iCloud sync is busy or unavailable. Check sync status.")
        }

        XCTAssertEqual(retries.count, 0)
    }

    @MainActor
    func testRetryThroughTheSimulatedHandlerRunsOnlyTheAppRetry() async throws {
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: defaults())
        await model.waitForInitialLoad()
        let retries = ApplicationCLIRetryCounter()
        let otherSyncs = ApplicationCLIRetryCounter()
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let cloud = SimulatedCloudSyncHandler(
            syncWhenPossible: { otherSyncs.record() },
            retrySyncWhenPossible: { retries.record() },
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
            cloudSyncHandler: cloud, panel: { panel }
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
    let retry: @MainActor () async -> Void

    init(retry: @escaping @MainActor () async -> Void) { self.retry = retry }

    func syncWhenPossible() async {}
    func retrySyncWhenPossible() async { await retry() }
    func isCloudSyncActive() async throws -> Bool { true }
    func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] { [:] }
    func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL {
        throw SnipLibraryError.attachmentCopyFailed
    }
}
