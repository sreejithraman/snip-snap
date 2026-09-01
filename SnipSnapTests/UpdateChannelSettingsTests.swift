import XCTest
@testable import SnipSnap

final class UpdateChannelSettingsTests: XCTestCase {
    @MainActor
    func testChoicePersistsAndResetsOnlyWhenItChanges() throws {
        let suite = "UpdateChannelSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = UpdateChannelSettings(defaults: defaults)
        var resetCount = 0

        XCTAssertFalse(settings.includesBetaUpdates)
        XCTAssertEqual(settings.selectedChannels, [])

        settings.setIncludesBetaUpdates(true) { resetCount += 1 }
        XCTAssertTrue(settings.includesBetaUpdates)
        XCTAssertEqual(settings.selectedChannels, ["beta"])
        XCTAssertEqual(resetCount, 1)
        XCTAssertTrue(UpdateChannelSettings(defaults: defaults).includesBetaUpdates)

        settings.setIncludesBetaUpdates(true) { resetCount += 1 }
        XCTAssertEqual(resetCount, 1)

        settings.setIncludesBetaUpdates(false) { resetCount += 1 }
        XCTAssertEqual(settings.selectedChannels, [])
        XCTAssertEqual(resetCount, 2)
    }
}
