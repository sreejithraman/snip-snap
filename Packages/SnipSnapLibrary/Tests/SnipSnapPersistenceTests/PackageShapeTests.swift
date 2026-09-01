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

    func testJSONAdapterReopensSnipsThatShareAStoredAttachment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("snips.json")
        let sourceURL = directory.appendingPathComponent("note.txt")
        try Data("Shared".utf8).write(to: sourceURL)
        let firstLibrary: any SnipLibrary = try JSONSnipLibrary(fileURL: storeURL)

        let firstUpdate = try await firstLibrary.perform(
            .add(
                content: "First",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [sourceURL],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 100)
            ),
            sortedBy: .chronological
        )
        let attachment = try XCTUnwrap(firstUpdate.snapshot.snips.first?.attachments.first)
        let storedURL = try XCTUnwrap(firstUpdate.snapshot.attachmentURLs[attachment.id])
        _ = try await firstLibrary.perform(
            .add(
                content: "Second",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [storedURL],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 200)
            ),
            sortedBy: .chronological
        )

        let reopened: any SnipLibrary = try JSONSnipLibrary(fileURL: storeURL)
        let snapshot = await reopened.snapshot(sortedBy: .chronological)
        XCTAssertEqual(snapshot.snips.map(\.content), ["Second", "First"])
        XCTAssertEqual(Set(snapshot.snips.flatMap(\.attachments).map(\.id)), [attachment.id])
    }
}
