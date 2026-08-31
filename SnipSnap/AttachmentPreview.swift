import AppKit
import SwiftUI

enum AttachmentPreviewMetrics {
    static let side: CGFloat = 64
    static let cornerRadius: CGFloat = 10
    static let artworkInset: CGFloat = 12
    static let removeButtonOverflow: CGFloat = 4
}

struct AttachmentPreviewArtwork: View {
    let image: NSImage
    let fillsTile: Bool

    var body: some View {
        Group {
            if fillsTile {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(AttachmentPreviewMetrics.artworkInset)
            }
        }
        .frame(
            width: AttachmentPreviewMetrics.side,
            height: AttachmentPreviewMetrics.side
        )
        .attachmentPreviewSurface()
    }
}

struct AttachmentPreviewItem: Identifiable {
    enum Source {
        case file(URL, previewImage: NSImage?, fillsTile: Bool)
        case image(id: String, image: NSImage)
    }

    let id: String
    let fileName: String
    let source: Source

    init(url: URL) {
        id = url.standardizedFileURL.absoluteString
        fileName = url.lastPathComponent
        source = .file(url, previewImage: nil, fillsTile: true)
    }

    init(
        url: URL,
        previewImage: NSImage,
        fillsTile: Bool
    ) {
        id = url.standardizedFileURL.absoluteString
        fileName = url.lastPathComponent
        source = .file(url, previewImage: previewImage, fillsTile: fillsTile)
    }

    init(id: String, image: NSImage) {
        self.id = id
        fileName = "Clipboard image"
        source = .image(id: id, image: image)
    }

    init(attachment: SnipAttachment, url: URL) {
        id = attachment.id.uuidString
        fileName = attachment.fileName
        source = .file(url, previewImage: nil, fillsTile: true)
    }
}

struct AttachmentPreviewStrip: View {
    let items: [AttachmentPreviewItem]
    private let onPreview: ((URL) -> Void)?
    private let onRemove: ((URL) -> Void)?

    init(
        items: [AttachmentPreviewItem],
        onPreview: @escaping (URL) -> Void,
        onRemove: ((URL) -> Void)? = nil
    ) {
        self.items = items
        self.onPreview = onPreview
        self.onRemove = onRemove
    }

    init(items: [AttachmentPreviewItem]) {
        self.items = items
        onPreview = nil
        onRemove = nil
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: SnipSnapSpacing.relatedContent) {
                ForEach(items) { item in
                    preview(item)
                }
            }
            .padding(.top, onRemove == nil ? 0 : AttachmentPreviewMetrics.removeButtonOverflow)
            .padding(
                .trailing,
                onRemove == nil ? 0 : AttachmentPreviewMetrics.removeButtonOverflow
            )
        }
        .frame(
            height: AttachmentPreviewMetrics.side
                + (onRemove == nil ? 0 : AttachmentPreviewMetrics.removeButtonOverflow * 2)
        )
        .scrollIndicators(.hidden)
    }

    private func preview(_ item: AttachmentPreviewItem) -> some View {
        ZStack(alignment: .topTrailing) {
            AttachmentPreviewTile(
                item: item,
                onPreview: onPreview
            )

            if let onRemove, case let .file(url, _, _) = item.source {
                Button {
                    onRemove(url)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .contentShape(.circle)
                .offset(
                    x: AttachmentPreviewMetrics.removeButtonOverflow,
                    y: -AttachmentPreviewMetrics.removeButtonOverflow
                )
                .help("Remove \(item.fileName)")
                .accessibilityLabel("Remove \(item.fileName)")
            }
        }
    }
}

private struct AttachmentPreviewTile: View {
    let item: AttachmentPreviewItem
    let onPreview: ((URL) -> Void)?

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?

    var body: some View {
        switch item.source {
        case let .file(url, previewImage, fillsTile):
            if let onPreview {
                Button { onPreview(url) } label: {
                    previewImageView(preloaded: previewImage, fillsTile: fillsTile)
                        .accessibilityHidden(true)
                    .contentShape(
                        RoundedRectangle(
                            cornerRadius: AttachmentPreviewMetrics.cornerRadius,
                            style: .continuous
                        )
                    )
                }
                .buttonStyle(.plain)
                .help("Quick Look \(item.fileName)")
                .accessibilityLabel("Preview \(item.fileName)")
                .accessibilityHint("Shows a Quick Look preview")
                .task(id: thumbnailRequestID) {
                    await loadThumbnail(preloaded: previewImage, url: url)
                }
            } else {
                previewImageView(preloaded: previewImage, fillsTile: fillsTile)
                    .task(id: thumbnailRequestID) {
                        await loadThumbnail(preloaded: previewImage, url: url)
                    }
            }
        case let .image(_, image):
            AttachmentPreviewArtwork(image: image, fillsTile: true)
                .accessibilityLabel(item.fileName)
        }
    }

    private func loadThumbnail(preloaded: NSImage?, url: URL) async {
        guard preloaded == nil else { return }
        thumbnail = await PreviewImageCache.shared.fileThumbnail(
            url: url,
            size: CGSize(
                width: AttachmentPreviewMetrics.side,
                height: AttachmentPreviewMetrics.side
            ),
            scale: displayScale
        )
    }

    @ViewBuilder
    private func previewImageView(preloaded: NSImage?, fillsTile: Bool) -> some View {
        if let image = preloaded ?? thumbnail {
            AttachmentPreviewArtwork(image: image, fillsTile: fillsTile)
        } else {
            Color.clear
                .frame(
                    width: AttachmentPreviewMetrics.side,
                    height: AttachmentPreviewMetrics.side
                )
                .attachmentPreviewSurface()
                .overlay {
                    Image(systemName: "doc")
                        .font(.system(size: 24))
                        .foregroundStyle(SnipSnapColors.textSecondary)
                }
        }
    }

    private var thumbnailRequestID: String {
        "\(item.id)|\(displayScale)"
    }
}

private extension View {
    func attachmentPreviewSurface() -> some View {
        let shape = RoundedRectangle(
            cornerRadius: AttachmentPreviewMetrics.cornerRadius,
            style: .continuous
        )
        let edge = PanelEdgeStyle.media
        return background(SnipSnapColors.attachmentFill)
            .clipShape(shape)
            .overlay {
                shape.stroke(
                    edge.color,
                    lineWidth: edge.width
                )
            }
    }
}
