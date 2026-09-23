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

    static func shouldPrepare(fileName: String, contentType: String?) -> Bool {
        isImage(fileName: fileName, contentType: contentType)
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
    @State private var zoomScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var pinchOccurredDuringDrag = false
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .opacity(1 - min(0.65, dismissalDistance / 600))
                    .ignoresSafeArea()
                if let image {
                    Image(decorative: image, scale: displayScale, orientation: .up)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(effectiveZoom)
                        .offset(imageOffset(image: image, viewport: geometry.size))
                        .onTapGesture(count: 2) {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                zoomScale = zoomScale > 1 ? 1 : 2
                                panOffset = .zero
                            }
                        }
                        .accessibilityLabel("Image preview")
                } else if didFailToLoad {
                    ContentUnavailableView("Couldn’t open image", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.white)
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
                    .onEnded { value in
                        if effectiveZoom > 1 || pinchOccurredDuringDrag {
                            panOffset = boundedOffset(
                                CGSize(
                                    width: panOffset.width + value.translation.width,
                                    height: panOffset.height + value.translation.height
                                ),
                                image: image,
                                viewport: geometry.size,
                                scale: effectiveZoom
                            )
                        } else if value.translation.height > 100,
                                  abs(value.translation.height) > abs(value.translation.width) {
                            close()
                        }
                        pinchOccurredDuringDrag = false
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($magnification) { value, state, _ in
                        state = value.magnification
                    }
                    .onChanged { _ in
                        if dragTranslation != .zero { pinchOccurredDuringDrag = true }
                    }
                    .onEnded { value in
                        zoomScale = min(3, max(1, zoomScale * value.magnification))
                        panOffset = boundedOffset(
                            panOffset, image: image, viewport: geometry.size, scale: zoomScale
                        )
                    }
            )
            .task(id: url) {
                image = nil
                didFailToLoad = false
                zoomScale = 1
                panOffset = .zero
                pinchOccurredDuringDrag = false
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
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding()
                    .accessibilityIdentifier("dismiss-attachment-image")
            }
        }
    }

    private var effectiveZoom: CGFloat {
        min(3, max(1, zoomScale * magnification))
    }

    private var dismissalDistance: CGFloat {
        guard effectiveZoom == 1,
              !pinchOccurredDuringDrag,
              dragTranslation.height > 0,
              abs(dragTranslation.height) > abs(dragTranslation.width) else { return 0 }
        return dragTranslation.height
    }

    private func close() {
        dismissPresentation()
        dismiss()
    }

    private func imageOffset(image: CGImage, viewport: CGSize) -> CGSize {
        if effectiveZoom == 1 && !pinchOccurredDuringDrag {
            return CGSize(width: 0, height: reduceMotion ? 0 : dismissalDistance)
        }
        return boundedOffset(
            CGSize(
                width: panOffset.width + dragTranslation.width,
                height: panOffset.height + dragTranslation.height
            ),
            image: image,
            viewport: viewport,
            scale: effectiveZoom
        )
    }

    private func boundedOffset(
        _ offset: CGSize,
        image: CGImage?,
        viewport: CGSize,
        scale: CGFloat
    ) -> CGSize {
        guard let image, viewport.width > 0, viewport.height > 0 else { return .zero }
        let fittedScale = min(viewport.width / CGFloat(image.width), viewport.height / CGFloat(image.height))
        let horizontalLimit = max(0, (CGFloat(image.width) * fittedScale * scale - viewport.width) / 2)
        let verticalLimit = max(0, (CGFloat(image.height) * fittedScale * scale - viewport.height) / 2)
        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, offset.width)),
            height: min(verticalLimit, max(-verticalLimit, offset.height))
        )
    }
}

private actor FullScreenImageLoader {
    static let shared = FullScreenImageLoader()

    func isStillImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sourceType = CGImageSourceGetType(source),
              UTType(sourceType as String)?.conforms(to: .image) == true else { return false }
        // Quick Look preserves playback for animated images.
        return CGImageSourceGetCount(source) == 1
    }

    func image(for url: URL, size: CGSize) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maxPixelSize = max(1, Int(ceil(max(size.width, size.height))))
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
