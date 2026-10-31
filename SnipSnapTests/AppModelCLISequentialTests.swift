import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest
@testable import SnipSnap

final class AppModelCLISequentialTests: StoreBackedTestCase {
    @MainActor
    func testSuccessfulUpdateReceiptsPermitTheNextIndependentWriteAndPersistDone() async throws {
        let url = try storeURL()
        let library = try SwiftDataSnipLibrary(storeURL: url)
        let model = AppModel(library: library, defaults: defaults())
        var current: [Snip] = []
        for content in ["First note", "Second note"] {
            let receipt = try await model.handleCLIRequest(.init(action: .add(
                content: content, list: nil, agentContext: nil)))
            XCTAssertEqual(receipt.status, .success)
            current.append(try XCTUnwrap(receipt.snips.first))
        }
        _ = try await library.perform(.setDone(ids: Set(current.map(\.id)), done: true),
                                      sortedBy: .manual)
        current = try await library.checkedSnapshot(sortedBy: .manual).snips
        var expectedContents = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.content) })

        for index in 0..<6 {
            let target = index % current.count
            let before = current[target]
            let content = "Updated note \(index + 1)"
            let request = SnipCLIRequest(action: .updateSnip(
                id: before.id, content: content, expectedUpdatedAt: before.updatedAt))
            let receipt = try await model.handleCLIRequest(request)
            XCTAssertEqual(receipt.requestID, request.requestID)
            XCTAssertEqual(receipt.status, .success)
            let saved = try XCTUnwrap(receipt.snips.first)
            XCTAssertEqual(saved.id, before.id)
            XCTAssertEqual(saved.content, content)
            XCTAssertTrue(saved.isDone)
            XCTAssertFalse(model.isCLIInteractionReserved)
            current[target] = saved
            expectedContents[saved.id] = content
        }

        let reopened = try SwiftDataSnipLibrary(storeURL: url)
        let persisted = try await reopened.checkedSnapshot(sortedBy: .manual).snips
        XCTAssertEqual(persisted.count, 2)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0.content) }),
                       expectedContents)
        XCTAssertTrue(persisted.allSatisfy(\.isDone))
    }
}
