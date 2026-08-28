import SnipSnapCore
import SnipSnapPersistence
import SwiftUI

@main
struct SnipSnapiOSApp: App {
    private let library: any SnipLibrary
    private let startupError: String?

    init() {
        let startup = Self.makeLibrary()
        library = startup.library
        startupError = startup.error
    }

    var body: some Scene {
        WindowGroup {
            IOSAppRootView(library: library, startupError: startupError)
        }
    }

    private static func makeLibrary() -> (library: any SnipLibrary, error: String?) {
        let environment = ProcessInfo.processInfo.environment
        let storeURL: URL

        if environment["SNIP_SNAP_UI_TESTING"] == "1" {
            let storeName = environment["SNIP_SNAP_UI_TEST_STORE"] ?? UUID().uuidString
            storeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(storeName, isDirectory: true)
                .appendingPathComponent("snips.store", isDirectory: false)
        } else {
            storeURL = SwiftDataSnipLibrary.defaultStoreURL()
        }

        do {
            return (try SwiftDataSnipLibrary(storeURL: storeURL), nil)
        } catch {
            return (
                SwiftDataSnipLibrary.unavailable(storeURL: storeURL),
                "Snip Snap could not open its local library. Your saved data was not changed."
            )
        }
    }
}
