import AppKit
import SnipSnapCore
import SwiftUI
import XCTest
@testable import SnipSnap

final class SnipCLIApplicationNavigationTests: StoreBackedTestCase {
    @MainActor
    func testSelectListExitsGlobalSearchAndDisplaysOnlyDestinationSnips() async throws {
        let fixture = await makeFixture()
        defer { fixture.coordinator.hidePanel(restoringPreviousApplication: false) }
        _ = try await handle(.search(query: "global match"), fixture)
        XCTAssertEqual(fixture.model.filteredSnips.map(\.content), ["global match"])

        _ = try await handle(.selectList(selector: "Research"), fixture)

        XCTAssertFalse(fixture.model.isSearchExpanded)
        XCTAssertEqual(fixture.model.query, "")
        XCTAssertFalse(fixture.model.isShowingClipboard)
        XCTAssertEqual(fixture.model.activeListID, fixture.destination.id)
        XCTAssertEqual(fixture.model.filteredSnips.map(\.content), ["Destination only"])
        XCTAssertTrue(fixture.panel.isVisible)
    }

    @MainActor
    func testUnknownListPreservesTheCurrentSearch() async throws {
        let fixture = await makeFixture()
        defer { fixture.coordinator.hidePanel(restoringPreviousApplication: false) }
        _ = try await handle(.search(query: "global match"), fixture)

        do {
            _ = try await handle(.selectList(selector: "Missing list"), fixture)
            XCTFail("An unknown destination must leave the current search intact.")
        } catch SnipLibraryError.invalidList {}

        XCTAssertEqual(fixture.model.activeListID, SnipList.inboxID)
        XCTAssertFalse(fixture.model.isShowingClipboard)
        XCTAssertTrue(fixture.model.isSearchExpanded)
        XCTAssertEqual(fixture.model.query, "global match")
        XCTAssertEqual(fixture.model.filteredSnips.map(\.content), ["global match"])
    }

    @MainActor
    func testClipboardExitsSearchAndRepeatedCommandsKeepItVisible() async throws {
        let fixture = await makeFixture()
        defer { fixture.coordinator.hidePanel(restoringPreviousApplication: false) }
        _ = try await handle(.search(query: "global match"), fixture)

        for _ in 0..<2 {
            let receipt = try await handle(.showClipboard, fixture)
            XCTAssertEqual(receipt.status, .success)
            XCTAssertTrue(fixture.model.isShowingClipboard)
            XCTAssertFalse(fixture.model.isSearchExpanded)
            XCTAssertEqual(fixture.model.query, "")
            XCTAssertTrue(fixture.panel.isVisible)
        }
        XCTAssertEqual(fixture.model.activeListID, SnipList.inboxID)
    }

    @MainActor
    func testCloseSearchRestoresThePreviousListAndViewWithoutOpeningThePanel() async throws {
        for clipboard in [false, true] {
            let fixture = await makeFixture()
            defer { fixture.coordinator.hidePanel(restoringPreviousApplication: false) }
            _ = try await handle(.selectList(selector: "Research"), fixture)
            if clipboard { _ = try await handle(.showClipboard, fixture) }
            _ = try await handle(.search(query: "global match"), fixture)
            fixture.coordinator.hidePanel(restoringPreviousApplication: false)

            for _ in 0..<2 {
                _ = try await handle(.closeSearch, fixture)
                XCTAssertFalse(fixture.model.isSearchExpanded)
                XCTAssertEqual(fixture.model.query, "")
                XCTAssertEqual(fixture.model.activeListID, fixture.destination.id)
                XCTAssertEqual(fixture.model.isShowingClipboard, clipboard)
                XCTAssertFalse(fixture.panel.isVisible)
            }
            if !clipboard {
                XCTAssertEqual(fixture.model.filteredSnips.map(\.content), ["Destination only"])
            }
        }
    }

    @MainActor
    func testNavigationRefusesAnOpenEditor() async throws {
        let fixture = await makeFixture()
        defer { fixture.coordinator.hidePanel(restoringPreviousApplication: false) }
        let snip = try XCTUnwrap(fixture.model.filteredSnips.first)
        let beganEditing = await fixture.model.beginEditing(snip.id)
        XCTAssertTrue(beganEditing)

        for action in navigationActions {
            do {
                _ = try await handle(action, fixture)
                XCTFail("Navigation must preserve the open editor: \(action)")
            } catch SnipCLIRequestError.editingInProgress {}
            XCTAssertEqual(fixture.model.editingID, snip.id)
            XCTAssertEqual(fixture.model.activeListID, SnipList.inboxID)
            XCTAssertFalse(fixture.model.isShowingClipboard)
            XCTAssertFalse(fixture.model.isSearchExpanded)
            XCTAssertEqual(fixture.model.query, "")
        }
    }

    @MainActor
    func testNavigationRefusesAnOpenFormAndPreservesSearch() async throws {
        let fixture = await makeFixture()
        defer { fixture.coordinator.hidePanel(restoringPreviousApplication: false) }
        _ = try await handle(.search(query: "global match"), fixture)
        fixture.coordinator.presentPanelDialog(id: .editList(UUID()), title: "Edit List", onDismiss: {}) {
            Text("Unsaved list name")
        }
        XCTAssertTrue(fixture.model.cliDialogIsPresented())

        for action in navigationActions {
            do {
                _ = try await handle(action, fixture)
                XCTFail("Navigation must preserve the open form: \(action)")
            } catch SnipCLIRequestError.editingInProgress {}
            XCTAssertTrue(fixture.model.cliDialogIsPresented())
            XCTAssertEqual(fixture.model.activeListID, SnipList.inboxID)
            XCTAssertFalse(fixture.model.isShowingClipboard)
            XCTAssertTrue(fixture.model.isSearchExpanded)
            XCTAssertEqual(fixture.model.query, "global match")
        }
    }

    @MainActor
    func testNavigationRefusesAReservedScopeTransition() async throws {
        let fixture = await makeFixture()
        defer { fixture.coordinator.hidePanel(restoringPreviousApplication: false) }
        _ = try await handle(.search(query: "global match"), fixture)
        try fixture.model.beginCLIScopeChange()
        defer { fixture.model.endCLIScopeChange() }

        for action in navigationActions {
            do {
                _ = try await handle(action, fixture)
                XCTFail("Navigation must wait for the scope transition: \(action)")
            } catch SnipLibraryError.modeTransitionInProgress {}
            XCTAssertEqual(fixture.model.activeListID, SnipList.inboxID)
            XCTAssertFalse(fixture.model.isShowingClipboard)
            XCTAssertTrue(fixture.model.isSearchExpanded)
            XCTAssertEqual(fixture.model.query, "global match")
        }
    }

    @MainActor
    func testNavigationRejectsAStaleScopeWithoutChangingTheView() async throws {
        let fixture = await makeFixture()
        defer { fixture.coordinator.hidePanel(restoringPreviousApplication: false) }
        _ = try await handle(.search(query: "global match"), fixture)

        for action in navigationActions {
            let request = SnipCLIRequest(action: .extended(.application(action)), scopeToken: "stale-scope")
            do {
                _ = try await fixture.handler.handle(request, action: action)
                XCTFail("Navigation must reject a stale scope: \(action)")
            } catch SnipCLIRequestError.scopeChanged {}
            XCTAssertEqual(fixture.model.activeListID, SnipList.inboxID)
            XCTAssertFalse(fixture.model.isShowingClipboard)
            XCTAssertTrue(fixture.model.isSearchExpanded)
            XCTAssertEqual(fixture.model.query, "global match")
        }
    }

    private var navigationActions: [SnipCLIApplicationAction] {
        [.selectList(selector: "Research"), .showClipboard, .closeSearch]
    }

    @MainActor
    private func makeFixture() async -> Fixture {
        let destination = SnipList(id: UUID(), name: "Research", systemImage: "folder", position: 1)
        let model = AppModel(library: InMemorySnipLibrary(snips: [
            Snip(content: "global match", origin: .quickEntry),
            Snip(content: "Destination only", origin: .quickEntry, listID: destination.id),
        ], lists: [.inbox, destination]), defaults: defaults())
        await model.waitForInitialLoad()
        let coordinator = AppCoordinator(
            model: model, shortcutSettings: ShortcutSettings(defaults: defaults()),
            isAccessibilityTrusted: { true }, accessibilitySetupDefaults: defaults()
        )
        let panel = NSWindow()
        coordinator.attachPanelWindow(panel)
        let handler = SnipCLIApplicationHandler(
            model: model, coordinator: coordinator,
            syncedContentSettings: SyncedContentSettingsModel(mode: .iCloudSync),
            updates: SnipCLIApplicationUpdates(settings: UpdateChannelSettings(defaults: defaults())),
            cloudSyncHandler: nil, accountNoticeModel: nil, panel: { panel }
        )
        return Fixture(model: model, coordinator: coordinator, handler: handler,
                       panel: panel, destination: destination)
    }

    @MainActor
    private func handle(_ action: SnipCLIApplicationAction, _ fixture: Fixture) async throws -> SnipCLIReceipt {
        let request = SnipCLIRequest(action: .extended(.application(action)), scopeToken: fixture.model.cliScopeToken)
        return try await fixture.handler.handle(request, action: action)
    }

    @MainActor
    private struct Fixture {
        let model: AppModel
        let coordinator: AppCoordinator
        let handler: SnipCLIApplicationHandler
        let panel: NSWindow
        let destination: SnipList
    }
}
