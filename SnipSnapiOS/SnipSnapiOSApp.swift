import SnipSnapCore
import SnipSnapPersistence
import SwiftUI

@main
struct SnipSnapiOSApp: App {
    private let library: any SnipLibrary
    private let startupError: String?
    private let uiTestAttachmentURLs: [URL]
    private let seedsCopyShareFixtures: Bool

    init() {
        let startup = Self.makeLibrary()
        library = startup.library
        startupError = startup.error
        uiTestAttachmentURLs = startup.uiTestAttachmentURLs
        seedsCopyShareFixtures = startup.seedsCopyShareFixtures
    }

    var body: some Scene {
        WindowGroup {
            IOSAppRootView(
                library: library,
                startupError: startupError,
                uiTestAttachmentURLs: uiTestAttachmentURLs,
                seedsCopyShareFixtures: seedsCopyShareFixtures
            )
        }
    }

    private static func makeLibrary() -> (
        library: any SnipLibrary,
        error: String?,
        uiTestAttachmentURLs: [URL],
        seedsCopyShareFixtures: Bool
    ) {
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
            let seedsCopyShareFixtures = environment["SNIP_SNAP_UI_TEST_COPY_SHARE"] == "1"
            let fixtureURLs = environment["SNIP_SNAP_UI_TEST_ATTACHMENTS"] == "1"
                    || seedsCopyShareFixtures
                ? makeUITestAttachmentFiles(nextTo: storeURL) : []
            return (
                try SwiftDataSnipLibrary(storeURL: storeURL),
                nil,
                fixtureURLs,
                seedsCopyShareFixtures
            )
        } catch {
            return (
                SwiftDataSnipLibrary.unavailable(storeURL: storeURL),
                "Snip Snap could not open its local library. Your saved data was not changed.",
                [],
                false
            )
        }
    }

    private static func makeUITestAttachmentFiles(nextTo storeURL: URL) -> [URL] {
        let directory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("UITestFixtures", isDirectory: true)
        let imageURL = directory.appendingPathComponent("sample.png", isDirectory: false)
        let textURL = directory.appendingPathComponent("notes.txt", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let png = Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            ) ?? Data()
            try png.write(to: imageURL, options: .atomic)
            try Data("A local file attachment".utf8).write(to: textURL, options: .atomic)
            return [imageURL, textURL]
        } catch {
            return []
        }
    }
}
