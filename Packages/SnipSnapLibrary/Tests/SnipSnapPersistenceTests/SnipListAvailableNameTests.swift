import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

final class SnipListAvailableNameTests: XCTestCase {
    func testStoreAllocatesNamesDuringConcurrentCreatesAndStillRejectsExactDuplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("library.json"))
        _ = try await library.perform(.createList(name: "New List", systemImage: "list.bullet"), sortedBy: .manual)
        let command = SnipLibraryCommand.createList(name: "New List", systemImage: "list.bullet", namePolicy: .available)
        async let first = library.perform(command, sortedBy: .manual)
        async let second = library.perform(command, sortedBy: .manual)
        _ = try await (first, second)
        let snapshot = await library.snapshot(sortedBy: .manual)
        XCTAssertEqual(Set(snapshot.lists.map(\.name)), ["Inbox", "New List", "New List (2)", "New List (3)"])
        do {
            _ = try await library.perform(.createList(name: "New List", systemImage: "list.bullet"), sortedBy: .manual)
            XCTFail("User-chosen duplicate names must still fail.")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .duplicateList)
        }
    }

    func testUsesBaseWhenFreeAndSkipsTakenSuffixes() {
        XCTAssertEqual(SnipListNameAllocator.availableName(startingWith: "New List", in: [.inbox]), "New List")
        let lists = [list("New List"), list("New List (2)"), list("New List (4)")]
        XCTAssertEqual(SnipListNameAllocator.availableName(startingWith: "New List", in: lists), "New List (3)")
    }

    func testUsesTheSameNameComparisonAsTheLibrary() {
        let lists = [list("  NÉW   LIST  "), list("Ｎｅｗ Ｌｉｓｔ （２）")]
        XCTAssertEqual(SnipListNameAllocator.availableName(startingWith: "New List", in: lists), "New List (3)")
    }

    func testAvoidsBothStoredAndDisplayedNamesAfterSync() {
        var synced = list("New List")
        synced.resolvedName = "New List (2)"
        XCTAssertEqual(SnipListNameAllocator.availableName(startingWith: "New List", in: [synced]), "New List (3)")
    }

    func testKeepsLocalizedBaseName() {
        XCTAssertEqual(SnipListNameAllocator.availableName(startingWith: "Neue Liste", in: [list("Neue Liste")]), "Neue Liste (2)")
    }

    private func list(_ name: String) -> SnipList {
        SnipList(id: UUID(), name: name, systemImage: "list.bullet", position: 1)
    }
}
