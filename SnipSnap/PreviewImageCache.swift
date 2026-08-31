import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

private struct LoadedPreview: @unchecked Sendable {
    let image: NSImage?
    let cost: Int

    static let missing = LoadedPreview(image: nil, cost: 0)
}

@MainActor
final class PreviewImageCache {
    static let shared = PreviewImageCache()

    private struct InFlightPreview {
        let task: Task<LoadedPreview, Never>
        var waiters: Set<UUID>
    }

    private let cache = NSCache<NSString, NSImage>()
    private let resolvedFileKeys = NSCache<NSString, NSString>()
    private var inFlight: [String: InFlightPreview] = [:]

    private init() {
        cache.countLimit = 180
        cache.totalCostLimit = 96 * 1_024 * 1_024
        resolvedFileKeys.countLimit = 360
    }

    func clipboardImage(
        id: UUID,
        variant: Int = 0,
        data: Data,
        size: CGSize,
        scale: CGFloat
    ) async -> NSImage? {
        let key = "clipboard-\(id.uuidString)-\(variant)-\(Self.pixelLength(size, scale: scale))"
        return await cachedImage(for: key) {
            Task.detached(priority: .userInitiated) {
                Self.imageThumbnail(data: data, size: size, scale: scale)
            }
        }
    }

    func fileThumbnail(url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        let lookupKey = Self.fileLookupKey(url: url, size: size, scale: scale)
        let key = await Task.detached(priority: .utility) {
            Self.fileThumbnailKey(url: url, size: size, scale: scale)
        }.value
        resolvedFileKeys.setObject(key as NSString, forKey: lookupKey as NSString)
        return await cachedImage(for: key) {
            Task.detached(priority: .userInitiated) {
                await Self.loadFileThumbnail(url: url, size: size, scale: scale)
            }
        }
    }

    func cachedFileThumbnail(url: URL, scale: CGFloat) -> NSImage? {
        let sharedTileSize = CGSize(
            width: AttachmentPreviewMetrics.side,
            height: AttachmentPreviewMetrics.side
        )
        let lookupKey = Self.fileLookupKey(
            url: url,
            size: sharedTileSize,
            scale: scale
        )
        guard let resolvedKey = resolvedFileKeys.object(
            forKey: lookupKey as NSString
        ) else { return nil }
        return cache.object(forKey: resolvedKey)
    }

    private func cachedImage(
        for key: String,
        makeTask: () -> Task<LoadedPreview, Never>
    ) async -> NSImage? {
        if let image = cache.object(forKey: key as NSString) { return image }

        let waiterID = UUID()
        let task: Task<LoadedPreview, Never>
        if var request = inFlight[key] {
            request.waiters.insert(waiterID)
            inFlight[key] = request
            task = request.task
        } else {
            task = makeTask()
            inFlight[key] = InFlightPreview(task: task, waiters: [waiterID])
        }

        let preview = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.releaseWaiter(waiterID, for: key)
            }
        }
        releaseWaiter(waiterID, for: key)

        guard !Task.isCancelled, let image = preview.image else { return nil }
        cache.setObject(image, forKey: key as NSString, cost: preview.cost)
        return image
    }

    private func releaseWaiter(_ waiterID: UUID, for key: String) {
        guard var request = inFlight[key], request.waiters.remove(waiterID) != nil else {
            return
        }
        if request.waiters.isEmpty {
            request.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = request
        }
    }

    private nonisolated static func imageThumbnail(
        data: Data,
        size: CGSize,
        scale: CGFloat
    ) -> LoadedPreview {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = makeImageThumbnail(source: source, size: size, scale: scale) else {
            return .missing
        }
        return LoadedPreview(
            image: NSImage(cgImage: cgImage, size: size),
            cost: decodedCost(of: cgImage)
        )
    }

    private nonisolated static func loadFileThumbnail(
        url: URL,
        size: CGSize,
        scale: CGFloat
    ) async -> LoadedPreview {
        if !Task.isCancelled,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cgImage = makeImageThumbnail(source: source, size: size, scale: scale) {
            return LoadedPreview(
                image: NSImage(cgImage: cgImage, size: size),
                cost: decodedCost(of: cgImage)
            )
        }
        guard !Task.isCancelled else { return .missing }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: [.thumbnail, .icon]
        )
        if let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request),
           !Task.isCancelled {
            return LoadedPreview(
                image: representation.nsImage,
                cost: decodedCost(of: representation.cgImage)
            )
        }
        guard !Task.isCancelled,
              let text = textFileContents(url: url) else { return .missing }
        return await MainActor.run {
            guard !Task.isCancelled else { return .missing }
            let image = textFilePreview(text: text, size: size)
            return LoadedPreview(image: image, cost: decodedCost(of: image))
        }
    }

    private nonisolated static func makeImageThumbnail(
        source: CGImageSource,
        size: CGSize,
        scale: CGFloat
    ) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelLength(size, scale: scale)
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private nonisolated static func textFileContents(url: URL) -> String? {
        let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        guard contentType?.conforms(to: .text) == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: 64 * 1_024)
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func textFilePreview(text: String, size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        SnipSnapColors.documentPreviewPaper.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = 2
        (text as NSString).draw(
            in: NSRect(
                x: 6,
                y: 6,
                width: max(0, size.width - 12),
                height: max(0, size.height - 12)
            ),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular),
                .foregroundColor: SnipSnapColors.documentPreviewInk,
                .paragraphStyle: paragraph
            ]
        )
        image.unlockFocus()
        return image
    }

    private nonisolated static func decodedCost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    private nonisolated static func decodedCost(of image: NSImage) -> Int {
        image.representations
            .map { max(0, $0.pixelsWide) * max(0, $0.pixelsHigh) * 4 }
            .max() ?? 0
    }

    private nonisolated static func pixelLength(_ size: CGSize, scale: CGFloat) -> Int {
        max(1, Int(ceil(max(size.width, size.height) * scale)))
    }

    private nonisolated static func fileLookupKey(
        url: URL,
        size: CGSize,
        scale: CGFloat
    ) -> String {
        "file-\(url.standardizedFileURL.path)-\(Int(size.width))x\(Int(size.height))-\(scale)"
    }

    private nonisolated static func fileThumbnailKey(
        url: URL,
        size: CGSize,
        scale: CGFloat
    ) -> String {
        let modificationDate = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        let changeStamp = modificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(fileLookupKey(url: url, size: size, scale: scale))-\(changeStamp)"
    }
}
