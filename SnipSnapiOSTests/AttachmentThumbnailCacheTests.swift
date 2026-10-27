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
final class AttachmentThumbnailCacheTests: XCTestCase {
    func testClipboardThumbnailDownsamplesAndReusesAcrossPreviewRefresh() async throws {
        let cache = AttachmentThumbnailCache()
        let source = thumbnailTestImage(width: 1024, height: 512)
        let data = try XCTUnwrap(UIImage(cgImage: source).pngData())
        let entry = ClipboardEntry(items: [.init(representations: [.init(type: UTType.png.identifier, data: data)])])
        let id = ClipboardImageThumbnailID(entry: entry, representationIndex: 0)
        let size = CGSize(width: 64, height: 64)
        XCTAssertNil(cache.cachedClipboardImage(id: id, size: size, scale: 3))
        let loaded = await cache.clipboardImage(data: data, id: id, size: size, scale: 3)
        let first = try XCTUnwrap(loaded)
        XCTAssertEqual(first.width, 192)
        XCTAssertEqual(first.height, 96)
        let refreshed = await cache.clipboardImage(data: data, id: id, size: size, scale: 3)
        XCTAssertTrue(first === refreshed)
        XCTAssertTrue(first === cache.cachedClipboardImage(id: id, size: size, scale: 3))
        let higherScale = await cache.clipboardImage(data: data, id: id, size: size, scale: 4)
        XCTAssertEqual(higherScale?.width, 256)
        XCTAssertEqual(data, UIImage(cgImage: source).pngData())
    }

    func testClipboardThumbnailVersionsKeepDifferentPayloadsAndVariantsSeparate() async throws {
        let cache = AttachmentThumbnailCache()
        let entryID = UUID()
        let firstData = try XCTUnwrap(UIImage(cgImage: thumbnailTestImage(width: 500, height: 250)).pngData())
        let secondData = try XCTUnwrap(UIImage(cgImage: thumbnailTestImage(width: 250, height: 500)).pngData())
        let entry = ClipboardEntry(id: entryID, items: [firstData, secondData].map {
            .init(representations: [.init(type: UTType.png.identifier, data: $0)])
        })
        var changed = entry
        changed.items[0] = .init(representations: [.init(type: UTType.png.identifier, data: secondData)])
        let firstID = ClipboardImageThumbnailID(entry: entry, representationIndex: 0)
        let replacementID = ClipboardImageThumbnailID(entry: changed, representationIndex: 0)
        let alternateID = ClipboardImageThumbnailID(entry: entry, representationIndex: 1)
        let size = CGSize(width: 64, height: 64)
        let first = await cache.clipboardImage(data: firstData, id: firstID, size: size, scale: 2)
        XCTAssertNil(cache.cachedClipboardImage(id: replacementID, size: size, scale: 2))
        XCTAssertNil(cache.cachedClipboardImage(id: alternateID, size: size, scale: 2))
        let replacement = await cache.clipboardImage(data: secondData, id: replacementID, size: size, scale: 2)
        XCTAssertEqual(first?.width, 128)
        XCTAssertEqual(first?.height, 64)
        XCTAssertEqual(replacement?.width, 64)
        XCTAssertEqual(replacement?.height, 128)
        let alternate = await cache.clipboardImage(data: secondData, id: alternateID, size: size, scale: 2)
        XCTAssertEqual(alternate?.height, 128)
        XCTAssertTrue(first === cache.cachedClipboardImage(id: firstID, size: size, scale: 2))

        var pinned = entry
        pinned.pinnedAt = Date()
        let pinnedID = ClipboardImageThumbnailID(entry: pinned, representationIndex: 0)
        let refreshed = await cache.clipboardImage(data: firstData, id: pinnedID, size: size, scale: 2)
        XCTAssertTrue(first === refreshed)
    }

    func testClipboardThumbnailHonorsImageOrientationAndRejectsInvalidBytes() async throws {
        let cache = AttachmentThumbnailCache()
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, thumbnailTestImage(width: 800, height: 400), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let size = CGSize(width: 64, height: 64)
        let entry = ClipboardEntry(items: [.init(representations: [.init(type: UTType.jpeg.identifier, data: bytes as Data)])])
        let orientedID = ClipboardImageThumbnailID(entry: entry, representationIndex: 0)
        let oriented = await cache.clipboardImage(data: bytes as Data, id: orientedID, size: size, scale: 3)
        XCTAssertEqual(oriented?.width, 96)
        XCTAssertEqual(oriented?.height, 192)
        let invalidData = Data([1, 2, 3])
        let invalidEntry = ClipboardEntry(items: [.init(representations: [.init(type: UTType.png.identifier, data: invalidData)])])
        let invalidID = ClipboardImageThumbnailID(entry: invalidEntry, representationIndex: 0)
        let invalid = await cache.clipboardImage(data: invalidData, id: invalidID, size: size, scale: 3)
        XCTAssertNil(invalid)
        XCTAssertNil(cache.cachedClipboardImage(id: invalidID, size: size, scale: 3))
    }

    func testLargeClipboardImageDecodeBenchmark() async throws {
        let context = CGContext(data: nil, width: 4096, height: 4096, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: 4096, by: 32) {
            context.setFillColor(red: CGFloat(y % 256) / 255, green: 0.25, blue: 0.75, alpha: 1)
            context.fill(CGRect(x: 0, y: y, width: 4096, height: 32))
        }
        let data = UIImage(cgImage: context.makeImage()!).jpegData(compressionQuality: 0.9)!
        var full: [Double] = []
        var thumb: [Double] = []
        var warm: [Double] = []
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        let entry = ClipboardEntry(items: (0..<3).map { _ in
            .init(representations: [.init(type: UTType.jpeg.identifier, data: data)])
        })
        let ids = (0..<3).map { ClipboardImageThumbnailID(entry: entry, representationIndex: $0) }
        for _ in 0..<15 {
            let start = CACurrentMediaTime()
            for _ in 0..<3 {
                autoreleasepool {
                    let image = UIImage(data: data)!
                    _ = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                }
            }
            full.append((CACurrentMediaTime() - start) * 1000)
            let cache = AttachmentThumbnailCache()
            let asyncStart = CACurrentMediaTime()
            for id in ids { _ = await cache.clipboardImage(data: data, id: id, size: size, scale: 3) }
            thumb.append((CACurrentMediaTime() - asyncStart) * 1000)
            let warmStart = CACurrentMediaTime()
            for id in ids { _ = await cache.clipboardImage(data: data, id: id, size: size, scale: 3) }
            warm.append((CACurrentMediaTime() - warmStart) * 1000)
        }
        print("THUMBNAIL-BENCH full-three-ms=\(full) cold-three-ms=\(thumb) warm-three-ms=\(warm) jpeg-bytes=\(data.count)")
    }

    func testCachedThumbnailReturnsWhileAnotherImageIsDecoding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnipSnapThumbnailWait-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fast = root.appendingPathComponent("fast.png")
        let slow = root.appendingPathComponent("slow.png")
        try Data([1]).write(to: fast)
        try Data([2]).write(to: slow)
        let gate = ThumbnailDecodeGate()
        defer { gate.release() }
        let cache = AttachmentThumbnailCache { url, _, _ in
            if url.lastPathComponent == "slow.png" {
                await gate.block()
            }
            return thumbnailTestImage()
        }
        let size = CGSize(width: 32, height: 32)

        let first = await cache.image(for: fast, size: size, scale: 2)
        XCTAssertNotNil(first)
        let slowLoad = Task { await cache.image(for: slow, size: size, scale: 2) }
        await gate.waitUntilBlocked()

        let cachedLoadFinished = expectation(description: "Cached thumbnail returns while the other decode is blocked")
        let cachedLoad = Task {
            let image = await cache.image(for: fast, size: size, scale: 2)
            cachedLoadFinished.fulfill()
            return image
        }

        // Bound a stuck request without making runner speed part of the contract.
        await fulfillment(of: [cachedLoadFinished], timeout: 10)
        gate.release()
        let again = await cachedLoad.value
        _ = await slowLoad.value

        XCTAssertTrue(first === again)
        XCTAssertNotNil(cache.cachedImage(for: fast, size: size, scale: 2))
    }

    func testThumbnailIsReusedUntilTheFileChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnipSnapThumbnailReuse-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let photo = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3, 4]).write(to: photo)
        let counter = ThumbnailDecodeCounter()
        let cache = AttachmentThumbnailCache { _, _, _ in
            counter.record()
            return thumbnailTestImage(width: 4, height: 3)
        }
        let size = CGSize(width: 16, height: 16)

        XCTAssertNil(cache.cachedImage(for: photo, size: size, scale: 2))
        let loaded = await cache.image(for: photo, size: size, scale: 2)
        XCTAssertEqual(loaded?.width, 4)
        XCTAssertEqual(loaded?.height, 3)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(cache.cachedImage(for: photo, size: size, scale: 2)?.width, 4)

        let again = await cache.image(for: photo, size: size, scale: 2)
        XCTAssertEqual(again?.width, 4)
        XCTAssertEqual(counter.count, 1)

        try Data([9, 9, 9]).write(to: photo)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: photo.path
        )
        let replaced = await cache.image(for: photo, size: size, scale: 2)
        XCTAssertEqual(replaced?.width, 4)
        XCTAssertEqual(counter.count, 2)
    }

    func testCancellingTheOnlyThumbnailRequestDropsTheDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnipSnapThumbnailCancel-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let photo = root.appendingPathComponent("photo.png")
        try Data([1]).write(to: photo)
        let gate = ThumbnailDecodeGate()
        let counter = ThumbnailDecodeCounter()
        let cache = AttachmentThumbnailCache { _, _, _ in
            await withTaskCancellationHandler {
                await gate.block()
            } onCancel: {
                gate.release()
            }
            guard !Task.isCancelled else { return nil }
            counter.record()
            return thumbnailTestImage()
        }
        let size = CGSize(width: 16, height: 16)
        let load = Task { await cache.image(for: photo, size: size, scale: 2) }
        await gate.waitUntilBlocked()
        load.cancel()
        Task {
            try? await Task.sleep(for: .seconds(2))
            gate.release()
        }

        let result = await load.value
        XCTAssertNil(result)
        XCTAssertEqual(counter.count, 0)
        XCTAssertNil(cache.cachedImage(for: photo, size: size, scale: 2))
    }
}

private final class ThumbnailDecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ThumbnailDecodeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isBlocked = false
    private var isReleased = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        let entered: [CheckedContinuation<Void, Never>]? = lock.withLock {
            if isReleased { return nil }
            isBlocked = true
            let entered = blockedWaiters
            blockedWaiters.removeAll()
            return entered
        }
        guard let entered else { return }
        entered.forEach { $0.resume() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if isReleased { return true }
                releaseWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if isBlocked { return true }
                blockedWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        lock.lock()
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}
