import SnipSnapCore
import SnipSnapPersistence
import XCTest

final class PackageShapeTests: XCTestCase {
    func testInboxIsAvailableThroughCore() {
        XCTAssertEqual(SnipList.inbox.id, SnipList.inboxID)
    }

    func testJSONAdapterSupportsTheSharedCommandInterface() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library: any SnipLibrary = try JSONSnipLibrary(
            fileURL: directory.appendingPathComponent("snips.json")
        )

        let listUpdate = try await library.perform(
            .createList(name: "Work", systemImage: "briefcase"),
            sortedBy: .chronological
        )
        guard case .listCreated(let list) = listUpdate.outcome else {
            return XCTFail("Expected a created list.")
        }

        let addUpdate = try await library.perform(
            .add(
                content: "Shared behavior",
                origin: .quickEntry,
                source: nil,
                listID: list.id,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 100)
            ),
            sortedBy: .chronological
        )

        XCTAssertEqual(addUpdate.snapshot.snips.map(\.content), ["Shared behavior"])
        XCTAssertEqual(addUpdate.snapshot.snips.map(\.listID), [list.id])
        XCTAssertEqual(addUpdate.snapshot.lists.map(\.name), ["Inbox", "Work"])
    }

}
