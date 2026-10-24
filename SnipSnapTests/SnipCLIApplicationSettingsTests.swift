import Foundation
import SnipSnapCore
import XCTest
@testable import SnipSnap

final class SnipCLIApplicationSettingsTests: StoreBackedTestCase {
    @MainActor
    func testCLISettingsUseExistingPersistenceAndExplicitStates() throws {
        let preferences = defaults()
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: preferences)
        let updates = UpdateChannelSettings(defaults: preferences)
        func apply(_ key: SnipCLIApplicationSetting, _ value: String) throws {
            try SnipCLIApplicationSettings.apply(key, value: value, model: model,
                                                updates: updates, updatesAvailable: true)
        }
        try apply(.appearance, "dark")
        try apply(.sort, "manual")
        try apply(.completionFilter, "notDone")
        try apply(.clipboardOnlyPinned, "on")
        try apply(.clipboardOnlyPinned, "on")
        try apply(.clipboardNewestFirst, "off")
        try apply(.betaUpdates, "on")
        XCTAssertEqual(model.appearance, .dark)
        XCTAssertEqual(model.sortMode, .manual)
        XCTAssertEqual(model.completionFilter, .notDone)
        XCTAssertTrue(model.clipboardViewOptions.onlyPinned)
        XCTAssertFalse(model.clipboardViewOptions.newestFirst)
        XCTAssertTrue(updates.includesBetaUpdates)
        let reopened = AppModel(library: InMemorySnipLibrary(snips: []), defaults: preferences)
        XCTAssertEqual(reopened.appearance, .dark)
        XCTAssertEqual(reopened.sortMode, .manual)
        XCTAssertTrue(UpdateChannelSettings(defaults: preferences).includesBetaUpdates)
    }

    @MainActor
    func testCLISettingsRejectEditingAndInvalidValuesWithoutChangingPreferences() throws {
        let preferences = defaults()
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: preferences)
        let updates = UpdateChannelSettings(defaults: preferences)
        model.editingID = UUID()
        XCTAssertThrowsError(try SnipCLIApplicationSettings.apply(.appearance, value: "dark",
            model: model, updates: updates, updatesAvailable: true)) { error in
            guard case SnipCLIRequestError.editingInProgress = error else {
                return XCTFail("Expected editing conflict, got \(error)")
            }
        }
        XCTAssertEqual(model.appearance, .system)
        model.editingID = nil
        XCTAssertThrowsError(try SnipCLIApplicationSettings.apply(.appearance, value: "purple",
            model: model, updates: updates, updatesAvailable: true))
        XCTAssertEqual(model.appearance, .system)
        XCTAssertThrowsError(try SnipCLIApplicationSettings.apply(.betaUpdates, value: "on",
            model: model, updates: updates, updatesAvailable: false))
        XCTAssertFalse(updates.includesBetaUpdates)
    }

    @MainActor
    func testRepeatedExplicitBetaSettingDoesNotRestartUpdateCycle() throws {
        let preferences = defaults()
        let model = AppModel(library: InMemorySnipLibrary(snips: []), defaults: preferences)
        let updates = UpdateChannelSettings(defaults: preferences)
        var resets = 0
        for _ in 0..<2 {
            try SnipCLIApplicationSettings.apply(.betaUpdates, value: "on", model: model,
                updates: updates, updatesAvailable: true, resetUpdateCycle: { resets += 1 })
        }
        XCTAssertEqual(resets, 1)
    }
}
