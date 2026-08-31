import XCTest
import SnipSnapCore
import Foundation
@testable import SnipSnap

class StoreBackedTestCase: XCTestCase {
    func storeURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip SnapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("snips.json")
    }
}

enum StubHotKeyError: Error {
    case registration
}

@MainActor
final class StubGlobalHotKeyManager: GlobalHotKeyManaging {
    private let error: Error?
    private(set) var registeredConfigurations: [GlobalShortcutConfiguration] = []
    private(set) var unregisterCount = 0

    init(error: Error? = nil) {
        self.error = error
    }

    func register(configuration: GlobalShortcutConfiguration) throws {
        registeredConfigurations.append(configuration)
        if let error { throw error }
    }

    func unregister() {
        unregisterCount += 1
    }
}
