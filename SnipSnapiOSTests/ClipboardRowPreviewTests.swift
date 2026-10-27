import Observation
import ImageIO
import SnipSnapCore
import SnipSnapCloud
import SnipSnapPersistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SnipSnapiOS

@MainActor
final class ClipboardRowPreviewTests: XCTestCase {
    func testInlineImageRowReusesThumbnailsAfterRefreshAndCopiesOriginalBytes() async throws {
        let previousPasteboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previousPasteboard }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = try [(1024, 512), (512, 1024), (1024, 1024)].map {
            try XCTUnwrap(UIImage(cgImage: thumbnailTestImage(width: $0.0, height: $0.1)).pngData())
        }
        let entry = ClipboardEntry(items: originals.map {
            .init(representations: [.init(type: UTType.png.identifier, data: $0)])
        }, plainText: "Three original clipboard images")
        let store = ClipboardHistoryStore(url: root.appendingPathComponent("clipboard.json"))
        _ = try await store.insert(entry)
        let preferencesName = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: preferencesName))
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let model = IOSClipboardModel(rootURL: root, settings: SyncedContentSettingsModel(mode: .localOnly), preferences: preferences)
        await model.load()
        let host = UIHostingController(rootView: ClipboardItemRow(entry: entry, model: model, onCopy: {}))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let size = CGSize(width: 64, height: 64)
        let scale = host.traitCollection.displayScale
        let keys = (0..<3).map { ClipboardImageThumbnailID(entry: entry, representationIndex: $0) }
        func cached() -> [CGImage] {
            keys.compactMap { AttachmentThumbnailCache.shared.cachedClipboardImage(id: $0, size: size, scale: scale) }
        }
        for _ in 0..<100 {
            if cached().count == 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let before = cached()
        XCTAssertEqual(before.count, 3)
        let revision = model.filePreviewRevision
        await model.load()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(model.filePreviewRevision, revision)
        XCTAssertEqual(cached().count, 3)
        XCTAssertTrue(zip(before, cached()).allSatisfy { $0 === $1 })
        XCTAssertTrue(cached().allSatisfy { max($0.width, $0.height) <= Int(64 * scale) })
        await model.copy(entry)
        XCTAssertEqual(UIPasteboard.general.data(forPasteboardType: UTType.png.identifier, inItemSet: IndexSet(integersIn: 0..<3)), originals)
        XCTAssertEqual(model.entries.first?.items, entry.items)
    }

    func testMountedRowReloadsRestoredFileAtTheSameURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let filesRoot = root.appendingPathComponent("ClipboardFiles", isDirectory: true)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        let url = filesRoot.appendingPathComponent("preview.png")
        func imageData(width: Int) -> Data {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: CGFloat(width), height: 3), format: format).pngData { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: 3))
            }
        }
        try imageData(width: 4).write(to: url)
        let entry = ClipboardEntry(items: [ClipboardPayloadItem(representations: [
            ClipboardRepresentation(type: UTType.fileURL.identifier, data: Data(url.absoluteString.utf8)),
        ])], ownedFiles: [ClipboardOwnedFile(name: "preview.png", relativePath: "preview.png")])
        let store = ClipboardHistoryStore(url: root.appendingPathComponent("clipboard.json"))
        _ = try await store.insert(entry)
        let preferencesName = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: preferencesName))
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let model = IOSClipboardModel(
            rootURL: root, settings: SyncedContentSettingsModel(mode: .localOnly), preferences: preferences
        )
        await model.load()
        let host = UIHostingController(rootView: ClipboardItemRow(entry: entry, model: model, onCopy: {}))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let scale = host.traitCollection.displayScale
        func waitForThumbnail(width: Int) async throws -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if AttachmentThumbnailCache.shared.cachedImage(
                    for: url, size: AttachmentThumbnailCache.tileSize, scale: scale
                )?.width == width { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        let initiallyLoaded = try await waitForThumbnail(width: 4)
        XCTAssertTrue(initiallyLoaded)
        try FileManager.default.removeItem(at: url)
        try imageData(width: 16).write(to: url)
        await model.load()
        XCTAssertEqual(model.entries.map(\.id), [entry.id])
        let restored = try await waitForThumbnail(width: 16)
        XCTAssertTrue(restored, "A mounted row must retry the same URL after its file is restored.")
    }
}
