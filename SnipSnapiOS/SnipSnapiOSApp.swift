import SnipSnapCloud
import SnipSnapCore
import SnipSnapPersistence
import SwiftUI

@main
@MainActor
struct SnipSnapiOSApp: App {
    private let library: any SnipLibrary
    private let shareImports: ShareImportStore?
    private let startupError: String?
    private let uiTestAttachmentURLs: [URL]
    private let accountNoticeModel: AppleAccountNoticeModel?

    init() {
        let startup = Self.makeLibrary()
        library = startup.library
        shareImports = startup.shareImports
        startupError = startup.error
        uiTestAttachmentURLs = startup.uiTestAttachmentURLs
        if ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_ACCOUNT_NOTICE"] == "signedOut" {
            accountNoticeModel = AppleAccountNoticeModel(
                notice: .signedOut,
                handler: UITestAppleAccountCacheHandler()
            )
        } else if let handler = Self.makeAccountCacheHandler() {
            accountNoticeModel = AppleAccountNoticeModel(handler: handler)
        } else {
            accountNoticeModel = nil
        }
    }

    private static func makeAccountCacheHandler() -> AppleAccountCacheCoordinatorHandler? {
        guard let sharedRootURL = SnipSnapAppGroupContainer.resolve()?.url,
              let containerIdentifier = Bundle.main.object(
                forInfoDictionaryKey: "SnipSnapCloudKitContainerIdentifier"
              ) as? String
        else { return nil }
        return AppleAccountCacheCoordinatorHandler(
            syncRootURL: sharedRootURL.appendingPathComponent("SyncMode", isDirectory: true),
            containerIdentifier: containerIdentifier
        )
    }

    var body: some Scene {
        WindowGroup {
            IOSAppRootView(
                library: library,
                shareImports: shareImports,
                startupError: startupError,
                uiTestAttachmentURLs: uiTestAttachmentURLs,
                accountNoticeModel: accountNoticeModel
            )
        }
    }

    private static func makeLibrary() -> (
        library: any SnipLibrary,
        shareImports: ShareImportStore?,
        error: String?,
        uiTestAttachmentURLs: [URL]
    ) {
        let environment = ProcessInfo.processInfo.environment
        let storeURL: URL
        let shareImports: ShareImportStore?

        if environment["SNIP_SNAP_UI_TESTING"] == "1" {
            let storeName = environment["SNIP_SNAP_UI_TEST_STORE"] ?? UUID().uuidString
            let sharedRootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(storeName, isDirectory: true)
            storeURL = ShareImportStore.storeURL(in: sharedRootURL)
            shareImports = ShareImportStore(sharedRootURL: sharedRootURL)
        } else if let sharedRootURL = SnipSnapAppGroupContainer.resolve()?.url {
            storeURL = ShareImportStore.storeURL(in: sharedRootURL)
            shareImports = ShareImportStore(sharedRootURL: sharedRootURL)
        } else {
            storeURL = SwiftDataSnipLibrary.defaultStoreURL()
            shareImports = nil
        }

        do {
            let fixtureURLs = environment["SNIP_SNAP_UI_TEST_ATTACHMENTS"] == "1"
                ? makeUITestAttachmentFiles(nextTo: storeURL) : []
            return (
                try SwiftDataSnipLibrary(storeURL: storeURL),
                shareImports,
                nil,
                fixtureURLs
            )
        } catch {
            return (
                SwiftDataSnipLibrary.unavailable(storeURL: storeURL),
                shareImports,
                "Snip Snap could not open its local library. Your saved data was not changed.",
                []
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

private actor UITestAppleAccountCacheHandler: AppleAccountCacheHandling {
    private var didResolve = false
    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? {
        didResolve ? nil : .signedOut
    }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {
        didResolve = true
    }
}
