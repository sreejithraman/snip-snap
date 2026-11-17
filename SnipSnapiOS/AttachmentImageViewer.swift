import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum AttachmentImageType {
    static func isImage(fileName: String, contentType: String? = nil) -> Bool {
        let fileType = UTType(filenameExtension: URL(fileURLWithPath: fileName).pathExtension)
        let recordedType = contentType.flatMap { UTType($0) }
        return fileType?.conforms(to: .image) == true
            || recordedType?.conforms(to: .image) == true
    }
}

extension View {
    func attachmentPreview(_ selectedURL: Binding<URL?>, in urls: [URL] = []) -> some View {
        modifier(AttachmentPreviewPresentation(selectedURL: selectedURL, urls: urls))
    }
}

private struct AttachmentPreviewPresentation: ViewModifier {
    @Binding var selectedURL: URL?
    let urls: [URL]
    @State private var presentation: Presentation?

    private enum Presentation: Equatable {
        case image(URL)
        case quickLook(URL)
    }

    func body(content: Content) -> some View {
        content
            .task(id: selectedURL) {
                guard let selectedURL else {
                    presentation = nil
                    return
                }
                if case .quickLook = presentation {
                    presentation = .quickLook(selectedURL)
                    return
                }
                presentation = nil
                let isStillImage = await FullScreenImageLoader.shared.isStillImage(at: selectedURL)
                guard !Task.isCancelled, self.selectedURL == selectedURL else { return }
                presentation = isStillImage ? .image(selectedURL) : .quickLook(selectedURL)
            }
            .quickLookPreview(
                Binding(
                    get: {
                        if case .quickLook(let url) = presentation { return url }
                        return nil
                    },
                    set: { url in
                        if let url, case .quickLook = presentation {
                            presentation = .quickLook(url)
                        } else if url == nil {
                            presentation = nil
                        }
                        selectedURL = url
                    }
                ),
                in: urls
            )
            .fullScreenCover(isPresented: Binding(
                get: {
                    if case .image = presentation { return true }
                    return false
                },
                set: { if !$0 { selectedURL = nil } }
            )) {
                if case .image(let url) = presentation {
                    FullScreenAttachmentImage(url: url) { self.selectedURL = nil }
                        .presentationBackground(.clear)
                }
            }
    }
}

private struct FullScreenAttachmentImage: View {
    let url: URL
    let dismiss: () -> Void
    @Environment(\.dismiss) private var dismissPresentation
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: CGImage?
    @State private var didFailToLoad = false
    @State private var zoom = ImageViewerZoom()
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .opacity(1 - min(0.65, dismissalDistance / 600))
                    .ignoresSafeArea()
                if didFailToLoad {
                    ContentUnavailableView("Couldn’t open image", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.white)
                } else if let displayedImage {
                    Image(decorative: displayedImage, scale: displayScale, orientation: .up)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(zoom.effectiveScale(magnification: magnification))
                        .offset(zoom.displayOffset(
                            dragTranslation: dragTranslation,
                            magnification: magnification,
                            reduceMotion: reduceMotion,
                            in: ImageViewerBounds(image: displayedImage, viewport: geometry.size)
                        ))
                        .onTapGesture(count: 2) {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                zoom.toggle()
                            }
                        }
                        .accessibilityLabel("Image preview")
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .updating($dragTranslation) { value, state, _ in
                        state = value.translation
                    }
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onEnded { value in
                        let closes = zoom.dragEnded(
                            translation: value.translation,
                            magnification: magnification,
                            in: ImageViewerBounds(image: image, viewport: geometry.size)
                        )
                        if closes { close() }
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($magnification) { value, state, _ in
                        state = value.magnification
                    }
                    .onChanged { _ in
                        zoom.pinchChanged(whileDragging: dragTranslation != .zero)
                    }
                    .onEnded { value in
                        zoom.pinchEnded(
                            magnification: value.magnification,
                            in: ImageViewerBounds(image: image, viewport: geometry.size)
                        )
                    }
            )
            .onChange(of: isDragging) { _, dragging in
                if dragging { zoom.dragStarted() } else { zoom.dragStopped() }
            }
            .task(id: url) {
                didFailToLoad = false
                zoom = ImageViewerZoom()
                image = FullScreenImageLoader.shared.cachedImage(for: url)
                    ?? AttachmentThumbnailCache.shared.cachedImage(
                        for: url,
                        size: AttachmentThumbnailCache.tileSize,
                        scale: displayScale
                    )
                let pixels = CGSize(
                    width: geometry.size.width * displayScale * 2,
                    height: geometry.size.height * displayScale * 2
                )
                let decoded = await FullScreenImageLoader.shared.image(for: url, size: pixels)
                guard !Task.isCancelled else { return }
                guard let decoded else {
                    didFailToLoad = true
                    return
                }
                image = decoded
            }
            .overlay(alignment: .topTrailing) {
                Button("Done", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding()
                    .accessibilityIdentifier("dismiss-attachment-image")
            }
        }
    }

    private var displayedImage: CGImage? {
        if let image { return image }
        if let cached = FullScreenImageLoader.shared.cachedImage(for: url) { return cached }
        return AttachmentThumbnailCache.shared.cachedImage(
            for: url,
            size: AttachmentThumbnailCache.tileSize,
            scale: displayScale
        )
    }

    private var dismissalDistance: CGFloat {
        zoom.dismissalDistance(dragTranslation: dragTranslation, magnification: magnification)
    }

    private func close() {
        dismissPresentation()
        dismiss()
    }
}

/// Committed zoom and pan, and whether the current drag has seen a pinch.
struct ImageViewerZoom {
    /// Whether the drag has seen a pinch. A pinch during a drag turns it into a pan, even
    /// back at base zoom.
    private enum DragPinch {
        case none
        /// A pinch happened during the drag in progress.
        case seen
        /// The drag stopped after a pinch. Its end can still arrive; the next drag's start
        /// clears this.
        case seenBeforeStop
    }

    private(set) var scale: CGFloat = 1
    private(set) var offset: CGSize = .zero
    private var dragPinch = DragPinch.none

    mutating func toggle() {
        scale = scale > 1 ? 1 : 2
        offset = .zero
    }

    /// A pinch that arrives before the start is seen belongs to the new drag, so it stays.
    mutating func dragStarted() {
        if dragPinch == .seenBeforeStop { dragPinch = .none }
    }

    mutating func pinchChanged(whileDragging: Bool) {
        if whileDragging { dragPinch = .seen }
    }

    /// The drag ended or the system cancelled it. SwiftUI may report this before or after
    /// `dragEnded`, so the pinch mark stays readable by a late end.
    mutating func dragStopped() {
        if dragPinch == .seen { dragPinch = .seenBeforeStop }
    }

    mutating func pinchEnded(magnification: CGFloat, in bounds: ImageViewerBounds) {
        scale = min(3, max(1, scale * magnification))
        offset = bounds.bounded(offset, scale: scale)
    }

    /// Returns true when the drag is a swipe that closes the viewer.
    mutating func dragEnded(
        translation: CGSize,
        magnification: CGFloat,
        in bounds: ImageViewerBounds
    ) -> Bool {
        defer { dragPinch = .none }
        let zoom = effectiveScale(magnification: magnification)
        if zoom > 1 || dragPinch != .none {
            offset = bounds.bounded(
                CGSize(width: offset.width + translation.width, height: offset.height + translation.height),
                scale: zoom
            )
            return false
        }
        return translation.height > 100 && abs(translation.height) > abs(translation.width)
    }

    func effectiveScale(magnification: CGFloat) -> CGFloat {
        min(3, max(1, scale * magnification))
    }

    func dismissalDistance(dragTranslation: CGSize, magnification: CGFloat) -> CGFloat {
        guard !pans(at: effectiveScale(magnification: magnification)),
              dragTranslation.height > 0,
              abs(dragTranslation.height) > abs(dragTranslation.width) else { return 0 }
        return dragTranslation.height
    }

    func displayOffset(
        dragTranslation: CGSize,
        magnification: CGFloat,
        reduceMotion: Bool,
        in bounds: ImageViewerBounds
    ) -> CGSize {
        let zoom = effectiveScale(magnification: magnification)
        guard pans(at: zoom) else {
            let distance = dismissalDistance(dragTranslation: dragTranslation, magnification: magnification)
            return CGSize(width: 0, height: reduceMotion ? 0 : distance)
        }
        return bounds.bounded(
            CGSize(
                width: offset.width + dragTranslation.width,
                height: offset.height + dragTranslation.height
            ),
            scale: zoom
        )
    }

    /// Whether the drag in progress pans. A stopped drag's pinch no longer counts, so the
    /// next drag follows the finger.
    private func pans(at zoom: CGFloat) -> Bool {
        zoom > 1 || dragPinch == .seen
    }
}

/// How far a fitted image can pan inside the viewport.
struct ImageViewerBounds {
    /// Pixel size, or nil before an image loads.
    let imageSize: CGSize?
    let viewport: CGSize

    func bounded(_ offset: CGSize, scale: CGFloat) -> CGSize {
        guard let imageSize, viewport.width > 0, viewport.height > 0 else { return .zero }
        let fittedScale = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let horizontalLimit = max(0, (imageSize.width * fittedScale * scale - viewport.width) / 2)
        let verticalLimit = max(0, (imageSize.height * fittedScale * scale - viewport.height) / 2)
        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, offset.width)),
            height: min(verticalLimit, max(-verticalLimit, offset.height))
        )
    }
}

private extension ImageViewerBounds {
    init(image: CGImage?, viewport: CGSize) {
        self.init(
            imageSize: image.map { CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) },
            viewport: viewport
        )
    }
}

private actor FullScreenImageLoader {
    static let shared = FullScreenImageLoader()
    private nonisolated(unsafe) let cache: NSCache<NSString, FullScreenImageBox> = {
        let cache = NSCache<NSString, FullScreenImageBox>()
        cache.countLimit = 4
        cache.totalCostLimit = 160 * 1_024 * 1_024
        return cache
    }()

    nonisolated func cachedImage(for url: URL) -> CGImage? {
        cache.object(forKey: url.standardizedFileURL.path as NSString)?.image
    }

    func isStillImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sourceType = CGImageSourceGetType(source),
              UTType(sourceType as String)?.conforms(to: .image) == true else { return false }
        // Quick Look preserves playback for animated images.
        return CGImageSourceGetCount(source) == 1
    }

    func image(for url: URL, size: CGSize) async -> CGImage? {
        let needed = max(1, Int(ceil(max(size.width, size.height))))
        let path = url.standardizedFileURL.path as NSString
        let version = await Task.detached(priority: .utility) {
            Self.fileVersion(of: url)
        }.value
        if let cached = cache.object(forKey: path) {
            if cached.version == version,
               max(cached.image.width, cached.image.height) >= needed {
                return cached.image
            }
            cache.removeObject(forKey: path)
        }
        let task = Task.detached(priority: .userInitiated) {
            Self.makeThumbnail(url: url, maxPixelSize: needed)
        }
        let decoded = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard let decoded, !Task.isCancelled else { return nil }
        cache.setObject(
            FullScreenImageBox(decoded, version: version),
            forKey: path,
            cost: decoded.bytesPerRow * decoded.height
        )
        return decoded
    }

    private nonisolated static func fileVersion(of url: URL) -> String {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ])
        let identity = values?.fileResourceIdentifier.map(String.init(describing:))
            ?? url.standardizedFileURL.path
        let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let bytes = values?.fileSize ?? -1
        return "\(identity)|\(modified)|\(bytes)"
    }

    private nonisolated static func makeThumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

private final class FullScreenImageBox: NSObject, @unchecked Sendable {
    let image: CGImage
    let version: String
    init(_ image: CGImage, version: String) {
        self.image = image
        self.version = version
    }
}
